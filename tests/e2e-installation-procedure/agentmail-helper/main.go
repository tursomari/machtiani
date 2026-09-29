package main

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"time"

	agentmail "github.com/agentmail-to/agentmail-go"
	"github.com/agentmail-to/agentmail-go/option"
	"github.com/agentmail-to/agentmail-go/packages/param"
)

const usageText = `agentmail-helper uses AGENTMAIL_API_KEY from the environment.

Usage:
  agentmail-helper list-inboxes
  agentmail-helper get-inbox --id ID
  agentmail-helper get-organization
  agentmail-helper list-pods
  agentmail-helper create-inbox --client-id ID --display-name TEXT --metadata-run-id ID --metadata-role receiver|sender
  agentmail-helper delete-inbox --id ID
  agentmail-helper list-messages --inbox-id ID
  agentmail-helper list-threads --inbox-id ID
  agentmail-helper get-message --inbox-id ID --id ID
  agentmail-helper get-attachment --inbox-id ID --message-id ID --attachment-id ID
  agentmail-helper send --inbox-id ID --to ADDRESS --subject TEXT --text TEXT --idempotency KEY
  agentmail-helper send-with-attachment --inbox-id ID --to ADDRESS --subject TEXT --text TEXT --attachment PATH [--attachment-content-type CT] --idempotency KEY
  agentmail-helper lists --scope inbox|pod|org --scope-id ID --direction send|receive|reply --type allow|block
  agentmail-helper lists-create --scope inbox|pod|org --scope-id ID --direction send|receive|reply --type allow|block --entry ADDRESS
  agentmail-helper lists-delete --scope inbox|pod|org --scope-id ID --direction send|receive|reply --type allow|block --entry ADDRESS
  agentmail-helper lists-delete-by-composite --scope inbox|pod|org --scope-id ID --direction send|receive|reply --type allow|block --entry ADDRESS
  agentmail-helper --self-check-trust-boundary

Every successful command emits one minimal JSON value on stdout, except
get-attachment, which emits raw attachment bytes directly.
`

const trustedAgentMailBaseURL = "https://api.agentmail.to/"

var errTrustProbeBlocked = errors.New("trust-boundary probe transport blocked request")

type trustProbeHTTPClient struct {
	request *http.Request
}

func (probe *trustProbeHTTPClient) Do(request *http.Request) (*http.Response, error) {
	probe.request = request.Clone(request.Context())
	return nil, errTrustProbeBlocked
}

type inboxOutput struct {
	InboxID     string         `json:"inbox_id"`
	Email       string         `json:"email"`
	PodID       string         `json:"pod_id"`
	ClientID    string         `json:"client_id"`
	DisplayName string         `json:"display_name"`
	Metadata    map[string]any `json:"metadata"`
	CreatedAt   time.Time      `json:"created_at"`
}

type podOutput struct {
	PodID     string    `json:"pod_id"`
	ClientID  string    `json:"client_id"`
	Name      string    `json:"name"`
	CreatedAt time.Time `json:"created_at"`
}

type messageOutput struct {
	MessageID   string             `json:"message_id"`
	ThreadID    string             `json:"thread_id"`
	From        string             `json:"from"`
	To          []string           `json:"to"`
	Subject     string             `json:"subject"`
	Text        string             `json:"text,omitempty"`
	Labels      []string           `json:"labels"`
	InReplyTo   string             `json:"in_reply_to,omitempty"`
	Timestamp   time.Time          `json:"timestamp"`
	Attachments []attachmentOutput `json:"attachments,omitempty"`
}

type attachmentOutput struct {
	AttachmentID string `json:"attachment_id"`
	ID           string `json:"id"`
	Filename     string `json:"filename"`
	Name         string `json:"name"`
	ContentType  string `json:"content_type"`
	Size         int64  `json:"size"`
}

type threadOutput struct {
	ThreadID      string   `json:"thread_id"`
	LastMessageID string   `json:"last_message_id"`
	Senders       []string `json:"senders"`
	Recipients    []string `json:"recipients"`
	Subject       string   `json:"subject"`
	MessageCount  int64    `json:"message_count"`
	Labels        []string `json:"labels"`
}

type listOutput struct {
	Scope       string    `json:"scope"`
	ScopeID     string    `json:"scope_id"`
	Direction   string    `json:"direction"`
	ListType    string    `json:"type"`
	Entry       string    `json:"entry"`
	EntryType   string    `json:"entry_type"`
	ListTypeAPI string    `json:"list_type"`
	ReadOnly    bool      `json:"read_only"`
	Reason      string    `json:"reason"`
	CreatedAt   time.Time `json:"created_at"`
}

type listArgs struct {
	scope     string
	scopeID   string
	direction string
	listType  string
	entry     string
}

func main() {
	if err := run(os.Args[1:]); err != nil {
		fmt.Fprintf(os.Stderr, "ERROR: %s\n", sanitizeError(err))
		os.Exit(1)
	}
}

func run(args []string) error {
	if len(args) == 1 && args[0] == "--self-check-trust-boundary" {
		return selfCheckTrustBoundary()
	}
	if len(args) == 0 || args[0] == "--help" || args[0] == "-h" || args[0] == "help" {
		fmt.Fprint(os.Stdout, usageText)
		return nil
	}

	client, err := newTrustedClient(os.Getenv("AGENTMAIL_API_KEY"))
	if err != nil {
		return err
	}
	ctx, cancel := context.WithTimeout(context.Background(), 90*time.Second)
	defer cancel()

	switch args[0] {
	case "list-inboxes":
		if len(args) != 1 {
			return errors.New("list-inboxes takes no arguments")
		}
		return listInboxes(ctx, &client)
	case "get-inbox":
		id, err := parseRequiredID("get-inbox", args[1:])
		if err != nil {
			return err
		}
		inbox, err := client.Inboxes.Get(ctx, id)
		if err != nil {
			return err
		}
		return emit(inboxFromSDK(*inbox))
	case "get-organization":
		if len(args) != 1 {
			return errors.New("get-organization takes no arguments")
		}
		organization, err := client.Organizations.Get(ctx)
		if err != nil {
			return err
		}
		return emit(struct {
			OrganizationID string `json:"organization_id"`
		}{organization.OrganizationID})
	case "list-pods":
		if len(args) != 1 {
			return errors.New("list-pods takes no arguments")
		}
		return listPods(ctx, &client)
	case "create-inbox":
		return createInbox(ctx, &client, args[1:])
	case "delete-inbox":
		id, err := parseRequiredID("delete-inbox", args[1:])
		if err != nil {
			return err
		}
		if err := denyMutationID(id); err != nil {
			return err
		}
		if err := client.Inboxes.Delete(ctx, id); err != nil {
			return err
		}
		return emit(struct {
			Deleted bool   `json:"deleted"`
			InboxID string `json:"inbox_id"`
		}{true, id})
	case "list-messages":
		inboxID, err := parseRequiredInboxID("list-messages", args[1:])
		if err != nil {
			return err
		}
		return listMessages(ctx, &client, inboxID)
	case "list-threads":
		inboxID, err := parseRequiredInboxID("list-threads", args[1:])
		if err != nil {
			return err
		}
		return listThreads(ctx, &client, inboxID)
	case "get-message":
		return getMessage(ctx, &client, args[1:])
	case "get-attachment":
		return getAttachment(ctx, &client, args[1:])
	case "send":
		return sendMessage(ctx, &client, args[1:])
	case "send-with-attachment":
		return sendWithAttachment(ctx, &client, args[1:])
	case "lists":
		parsed, err := parseListArgs("lists", args[1:], false)
		if err != nil {
			return err
		}
		return listEntries(ctx, &client, parsed)
	case "lists-create":
		parsed, err := parseListArgs("lists-create", args[1:], true)
		if err != nil {
			return err
		}
		return createListEntry(ctx, &client, parsed)
	case "lists-delete", "lists-delete-by-composite":
		parsed, err := parseListArgs(args[0], args[1:], true)
		if err != nil {
			return err
		}
		return deleteListEntry(ctx, &client, parsed)
	default:
		return fmt.Errorf("unknown subcommand %q; use --help", args[0])
	}
}

func newTrustedClient(key string) (agentmail.Client, error) {
	var rejected []string
	for _, name := range []string{"AGENTMAIL_BASE_URL", "AGENTMAIL_CUSTOM_HEADERS"} {
		if _, present := os.LookupEnv(name); present {
			rejected = append(rejected, name)
		}
		if err := os.Unsetenv(name); err != nil {
			return agentmail.Client{}, fmt.Errorf("cannot clear untrusted %s: %w", name, err)
		}
	}
	if len(rejected) != 0 {
		return agentmail.Client{}, fmt.Errorf("untrusted AgentMail client environment is set: %s", strings.Join(rejected, ", "))
	}
	if strings.TrimSpace(key) == "" || strings.ContainsAny(key, "\r\n\x00") {
		return agentmail.Client{}, errors.New("AGENTMAIL_API_KEY must be a non-empty, single-line environment value")
	}

	// NewClient appends these explicit options after all SDK defaults. Keeping
	// the trusted endpoint and validated key here makes the transport boundary
	// independent of future SDK environment defaults.
	return agentmail.NewClient(
		option.WithBaseURL(trustedAgentMailBaseURL),
		option.WithAPIKey(key),
	), nil
}

func selfCheckTrustBoundary() error {
	const probeKey = "agentmail-helper-self-check-key"
	if err := os.Setenv("AGENTMAIL_BASE_URL", "http://127.0.0.1:1/untrusted/"); err != nil {
		return err
	}
	if err := os.Setenv("AGENTMAIL_CUSTOM_HEADERS", "X-Untrusted-Probe: present"); err != nil {
		return err
	}
	_, err := newTrustedClient(probeKey)
	if err == nil {
		return errors.New("trust-boundary self-check accepted ambient endpoint/header overrides")
	}
	if _, present := os.LookupEnv("AGENTMAIL_BASE_URL"); present {
		return errors.New("trust-boundary self-check did not clear AGENTMAIL_BASE_URL")
	}
	if _, present := os.LookupEnv("AGENTMAIL_CUSTOM_HEADERS"); present {
		return errors.New("trust-boundary self-check did not clear AGENTMAIL_CUSTOM_HEADERS")
	}
	if !strings.Contains(err.Error(), "AGENTMAIL_BASE_URL") || !strings.Contains(err.Error(), "AGENTMAIL_CUSTOM_HEADERS") {
		return fmt.Errorf("trust-boundary self-check returned an unexpected error: %w", err)
	}

	client, err := newTrustedClient(probeKey)
	if err != nil {
		return fmt.Errorf("trust-boundary self-check could not construct the cleared client: %w", err)
	}
	probe := &trustProbeHTTPClient{}
	ctx, cancel := context.WithTimeout(context.Background(), time.Second)
	defer cancel()
	err = client.Execute(ctx, http.MethodGet, "v0/inboxes", nil, nil,
		option.WithHTTPClient(probe), option.WithMaxRetries(0))
	if probe.request == nil || !errors.Is(err, errTrustProbeBlocked) {
		return errors.New("trust-boundary self-check did not stop the request in its no-egress transport")
	}
	if probe.request.URL.Scheme != "https" || probe.request.URL.Host != "api.agentmail.to" {
		return fmt.Errorf("trust-boundary self-check observed an untrusted request destination: %s", probe.request.URL.Redacted())
	}
	if probe.request.Header.Get("X-Untrusted-Probe") != "" {
		return errors.New("trust-boundary self-check observed an ambient custom header")
	}
	if probe.request.Header.Get("Authorization") != "Bearer "+probeKey {
		return errors.New("trust-boundary self-check observed an unexpected authorization header")
	}
	fmt.Fprintln(os.Stdout, "AgentMail trust-boundary self-check passed without network egress")
	return nil
}

func sanitizeError(err error) string {
	message := err.Error()
	if key := os.Getenv("AGENTMAIL_API_KEY"); key != "" {
		message = strings.ReplaceAll(message, key, "<redacted>")
	}
	return message
}

func emit(value any) error {
	encoder := json.NewEncoder(os.Stdout)
	encoder.SetEscapeHTML(false)
	return encoder.Encode(value)
}

func inboxFromSDK(inbox agentmail.Inbox) inboxOutput {
	metadata := make(map[string]any, len(inbox.Metadata))
	for key, value := range inbox.Metadata {
		switch {
		case value.JSON.OfString.Valid():
			metadata[key] = value.AsString()
		case value.JSON.OfFloat.Valid():
			metadata[key] = value.AsFloat()
		case value.JSON.OfBool.Valid():
			metadata[key] = value.AsBool()
		}
	}
	return inboxOutput{
		InboxID: inbox.InboxID, Email: inbox.Email, PodID: inbox.PodID,
		ClientID: inbox.ClientID, DisplayName: inbox.DisplayName,
		Metadata: metadata, CreatedAt: inbox.CreatedAt,
	}
}

func denyMutationID(value string) error {
	if forbidden := os.Getenv("AGENTMAIL_MUTATION_FORBIDDEN_ID"); forbidden != "" && value == forbidden {
		return errors.New("mutation target is the protected stable inbox ID")
	}
	return nil
}

func denyMutationAddress(value string) error {
	if forbidden := os.Getenv("AGENTMAIL_MUTATION_FORBIDDEN_ADDRESS"); forbidden != "" && strings.EqualFold(value, forbidden) {
		return errors.New("mutation target is the protected stable inbox address")
	}
	return nil
}

func createInbox(ctx context.Context, client *agentmail.Client, args []string) error {
	set := newFlagSet("create-inbox")
	clientID := set.String("client-id", "", "run-unique client ID")
	displayName := set.String("display-name", "", "run-unique display name")
	runID := set.String("metadata-run-id", "", "run metadata ID")
	role := set.String("metadata-role", "", "receiver or sender")
	if err := set.Parse(args); err != nil {
		return err
	}
	if set.NArg() != 0 {
		return errors.New("create-inbox received unexpected positional arguments")
	}
	for name, value := range map[string]string{"client-id": *clientID, "display-name": *displayName, "metadata-run-id": *runID, "metadata-role": *role} {
		if err := required(value, name); err != nil {
			return err
		}
	}
	if *role != "receiver" && *role != "sender" {
		return errors.New("--metadata-role must be receiver or sender")
	}
	params := agentmail.InboxNewParams{CreateInbox: agentmail.CreateInboxParam{
		ClientID:    param.NewOpt(*clientID),
		DisplayName: param.NewOpt(*displayName),
		Metadata: map[string]agentmail.CreateInboxMetadataUnionParam{
			"machtiani_ipe_run":  {OfString: param.NewOpt(*runID)},
			"machtiani_ipe_role": {OfString: param.NewOpt(*role)},
		},
	}}
	inbox, err := client.Inboxes.New(ctx, params)
	if err != nil {
		return err
	}
	if err := denyMutationID(inbox.InboxID); err != nil {
		return err
	}
	if err := denyMutationAddress(inbox.Email); err != nil {
		return err
	}
	return emit(inboxFromSDK(*inbox))
}

func listPods(ctx context.Context, client *agentmail.Client) error {
	items := make([]podOutput, 0)
	seen := map[string]bool{}
	pageToken := ""
	for {
		query := agentmail.PodListParams{Limit: param.NewOpt[int64](100)}
		if pageToken != "" {
			query.PageToken = param.NewOpt(pageToken)
		}
		page, err := client.Pods.List(ctx, query)
		if err != nil {
			return err
		}
		for _, pod := range page.Pods {
			items = append(items, podOutput{PodID: pod.PodID, ClientID: pod.ClientID, Name: pod.Name, CreatedAt: pod.CreatedAt})
		}
		if page.NextPageToken == "" {
			break
		}
		if seen[page.NextPageToken] {
			return errors.New("pod pagination returned a repeated page token")
		}
		seen[page.NextPageToken] = true
		pageToken = page.NextPageToken
	}
	return emit(struct {
		Pods []podOutput `json:"pods"`
	}{items})
}

func newFlagSet(name string) *flag.FlagSet {
	set := flag.NewFlagSet(name, flag.ContinueOnError)
	set.SetOutput(os.Stderr)
	set.Usage = func() { fmt.Fprintf(os.Stderr, "See agentmail-helper --help for %s usage.\n", name) }
	return set
}

func required(value, name string) error {
	if strings.TrimSpace(value) == "" || strings.ContainsAny(value, "\r\n\x00") {
		return fmt.Errorf("--%s is required and must be a non-empty, single-line value", name)
	}
	return nil
}

func parseRequiredID(command string, args []string) (string, error) {
	set := newFlagSet(command)
	id := set.String("id", "", "exact resource ID")
	if err := set.Parse(args); err != nil {
		return "", err
	}
	if set.NArg() != 0 {
		return "", fmt.Errorf("%s received unexpected positional arguments", command)
	}
	if err := required(*id, "id"); err != nil {
		return "", err
	}
	return *id, nil
}

func parseRequiredInboxID(command string, args []string) (string, error) {
	set := newFlagSet(command)
	inboxID := set.String("inbox-id", "", "exact inbox ID")
	if err := set.Parse(args); err != nil {
		return "", err
	}
	if set.NArg() != 0 {
		return "", fmt.Errorf("%s received unexpected positional arguments", command)
	}
	if err := required(*inboxID, "inbox-id"); err != nil {
		return "", err
	}
	return *inboxID, nil
}

func listInboxes(ctx context.Context, client *agentmail.Client) error {
	items := make([]inboxOutput, 0)
	seen := map[string]bool{}
	pageToken := ""
	for {
		query := agentmail.InboxListParams{Limit: param.NewOpt[int64](100)}
		if pageToken != "" {
			query.PageToken = param.NewOpt(pageToken)
		}
		page, err := client.Inboxes.List(ctx, query)
		if err != nil {
			return err
		}
		for _, inbox := range page.Inboxes {
			items = append(items, inboxFromSDK(inbox))
		}
		if page.NextPageToken == "" {
			break
		}
		if seen[page.NextPageToken] {
			return errors.New("inbox pagination returned a repeated page token")
		}
		seen[page.NextPageToken] = true
		pageToken = page.NextPageToken
	}
	return emit(struct {
		Inboxes []inboxOutput `json:"inboxes"`
	}{items})
}

func listMessages(ctx context.Context, client *agentmail.Client, inboxID string) error {
	items := make([]messageOutput, 0)
	seen := map[string]bool{}
	pageToken := ""
	for {
		query := agentmail.InboxMessageListParams{Limit: param.NewOpt[int64](100)}
		if pageToken != "" {
			query.PageToken = param.NewOpt(pageToken)
		}
		page, err := client.Inboxes.Messages.List(ctx, inboxID, query)
		if err != nil {
			return err
		}
		for _, message := range page.Messages {
			items = append(items, messageOutput{
				MessageID: message.MessageID,
				ThreadID:  message.ThreadID,
				From:      message.From,
				To:        message.To,
				Subject:   message.Subject,
				Labels:    message.Labels,
				InReplyTo: message.InReplyTo,
				Timestamp: message.Timestamp,
			})
		}
		if page.NextPageToken == "" {
			break
		}
		if seen[page.NextPageToken] {
			return errors.New("message pagination returned a repeated page token")
		}
		seen[page.NextPageToken] = true
		pageToken = page.NextPageToken
	}
	return emit(struct {
		Messages []messageOutput `json:"messages"`
	}{items})
}

func listThreads(ctx context.Context, client *agentmail.Client, inboxID string) error {
	items := make([]threadOutput, 0)
	seen := map[string]bool{}
	pageToken := ""
	for {
		query := agentmail.InboxThreadListParams{Limit: param.NewOpt[int64](100)}
		if pageToken != "" {
			query.PageToken = param.NewOpt(pageToken)
		}
		page, err := client.Inboxes.Threads.List(ctx, inboxID, query)
		if err != nil {
			return err
		}
		for _, thread := range page.Threads {
			items = append(items, threadOutput{
				ThreadID:      thread.ThreadID,
				LastMessageID: thread.LastMessageID,
				Senders:       thread.Senders,
				Recipients:    thread.Recipients,
				Subject:       thread.Subject,
				MessageCount:  thread.MessageCount,
				Labels:        thread.Labels,
			})
		}
		if page.NextPageToken == "" {
			break
		}
		if seen[page.NextPageToken] {
			return errors.New("thread pagination returned a repeated page token")
		}
		seen[page.NextPageToken] = true
		pageToken = page.NextPageToken
	}
	return emit(struct {
		Threads []threadOutput `json:"threads"`
	}{items})
}

func getMessage(ctx context.Context, client *agentmail.Client, args []string) error {
	set := newFlagSet("get-message")
	inboxID := set.String("inbox-id", "", "exact inbox ID")
	id := set.String("id", "", "exact message ID")
	if err := set.Parse(args); err != nil {
		return err
	}
	if set.NArg() != 0 {
		return errors.New("get-message received unexpected positional arguments")
	}
	if err := required(*inboxID, "inbox-id"); err != nil {
		return err
	}
	if err := required(*id, "id"); err != nil {
		return err
	}
	message, err := client.Inboxes.Messages.Get(ctx, *id, agentmail.InboxMessageGetParams{InboxID: *inboxID})
	if err != nil {
		return err
	}
	attachments := make([]attachmentOutput, 0, len(message.Attachments))
	for _, attachment := range message.Attachments {
		attachments = append(attachments, attachmentOutput{
			AttachmentID: attachment.AttachmentID,
			ID:           attachment.AttachmentID,
			Filename:     attachment.Filename,
			Name:         attachment.Filename,
			ContentType:  attachment.ContentType,
			Size:         attachment.Size,
		})
	}
	return emit(messageOutput{
		MessageID:   message.MessageID,
		ThreadID:    message.ThreadID,
		From:        message.From,
		To:          message.To,
		Subject:     message.Subject,
		Text:        message.Text,
		Labels:      message.Labels,
		InReplyTo:   message.InReplyTo,
		Timestamp:   message.Timestamp,
		Attachments: attachments,
	})
}

func newListOutput(scope, scopeID, direction, listType, entry, entryType string, readOnly bool, reason string, createdAt time.Time) listOutput {
	return listOutput{
		Scope: scope, ScopeID: scopeID, Direction: direction, ListType: listType,
		Entry: entry, EntryType: entryType, ListTypeAPI: listType,
		ReadOnly: readOnly, Reason: reason, CreatedAt: createdAt,
	}
}

func sendMessage(ctx context.Context, client *agentmail.Client, args []string) error {
	set := newFlagSet("send")
	inboxID := set.String("inbox-id", "", "exact inbox ID")
	to := set.String("to", "", "recipient address")
	subject := set.String("subject", "", "message subject")
	text := set.String("text", "", "plain text body")
	idempotency := set.String("idempotency", "", "idempotency key")
	if err := set.Parse(args); err != nil {
		return err
	}
	if set.NArg() != 0 {
		return errors.New("send received unexpected positional arguments")
	}
	for name, value := range map[string]string{
		"inbox-id":    *inboxID,
		"to":          *to,
		"subject":     *subject,
		"text":        *text,
		"idempotency": *idempotency,
	} {
		if err := required(value, name); err != nil {
			return err
		}
	}
	if err := denyMutationID(*inboxID); err != nil {
		return err
	}
	if err := denyMutationAddress(*to); err != nil {
		return err
	}
	body := agentmail.InboxMessageSendParams{SendMessageRequest: agentmail.SendMessageRequestParam{
		To:      agentmail.AddressesUnionParam{OfString: param.NewOpt(*to)},
		Subject: param.NewOpt(*subject),
		Text:    param.NewOpt(*text),
	}}
	response, err := client.Inboxes.Messages.Send(ctx, *inboxID, body, option.WithHeader("Idempotency-Key", *idempotency))
	if err != nil {
		return err
	}
	return emit(struct {
		MessageID string `json:"message_id"`
		ThreadID  string `json:"thread_id"`
	}{response.MessageID, response.ThreadID})
}

func sendWithAttachment(ctx context.Context, client *agentmail.Client, args []string) error {
	set := newFlagSet("send-with-attachment")
	inboxID := set.String("inbox-id", "", "exact inbox ID")
	to := set.String("to", "", "recipient address")
	subject := set.String("subject", "", "message subject")
	text := set.String("text", "", "plain text body")
	attachmentPath := set.String("attachment", "", "path to attachment file")
	attachmentContentType := set.String("attachment-content-type", "text/plain", "attachment content type")
	idempotency := set.String("idempotency", "", "idempotency key")
	if err := set.Parse(args); err != nil {
		return err
	}
	if set.NArg() != 0 {
		return errors.New("send-with-attachment received unexpected positional arguments")
	}
	for name, value := range map[string]string{
		"inbox-id":                *inboxID,
		"to":                      *to,
		"subject":                 *subject,
		"text":                    *text,
		"attachment":              *attachmentPath,
		"attachment-content-type": *attachmentContentType,
		"idempotency":             *idempotency,
	} {
		if err := required(value, name); err != nil {
			return err
		}
	}
	if err := denyMutationID(*inboxID); err != nil {
		return err
	}
	if err := denyMutationAddress(*to); err != nil {
		return err
	}
	content, err := os.ReadFile(*attachmentPath)
	if err != nil {
		return fmt.Errorf("read attachment %q: %w", *attachmentPath, err)
	}
	body := agentmail.InboxMessageSendParams{SendMessageRequest: agentmail.SendMessageRequestParam{
		To:      agentmail.AddressesUnionParam{OfString: param.NewOpt(*to)},
		Subject: param.NewOpt(*subject),
		Text:    param.NewOpt(*text),
		Attachments: []agentmail.SendAttachmentParam{{
			Content:     param.NewOpt(base64.StdEncoding.EncodeToString(content)),
			ContentType: param.NewOpt(*attachmentContentType),
			Filename:    param.NewOpt(filepath.Base(*attachmentPath)),
		}},
	}}
	response, err := client.Inboxes.Messages.Send(ctx, *inboxID, body, option.WithHeader("Idempotency-Key", *idempotency))
	if err != nil {
		return err
	}
	return emit(struct {
		MessageID string `json:"message_id"`
		ThreadID  string `json:"thread_id"`
	}{response.MessageID, response.ThreadID})
}

func getAttachment(ctx context.Context, client *agentmail.Client, args []string) error {
	set := newFlagSet("get-attachment")
	inboxID := set.String("inbox-id", "", "exact inbox ID")
	messageID := set.String("message-id", "", "exact source message ID")
	attachmentID := set.String("attachment-id", "", "exact attachment ID")
	if err := set.Parse(args); err != nil {
		return err
	}
	if set.NArg() != 0 {
		return errors.New("get-attachment received unexpected positional arguments")
	}
	for name, value := range map[string]string{
		"inbox-id":      *inboxID,
		"message-id":    *messageID,
		"attachment-id": *attachmentID,
	} {
		if err := required(value, name); err != nil {
			return err
		}
	}
	attachment, err := client.Inboxes.Messages.GetAttachment(ctx, *attachmentID, agentmail.InboxMessageGetAttachmentParams{
		InboxID:   *inboxID,
		MessageID: *messageID,
	})
	if err != nil {
		return err
	}
	request, err := http.NewRequestWithContext(ctx, http.MethodGet, attachment.DownloadURL, nil)
	if err != nil {
		return err
	}
	response, err := http.DefaultClient.Do(request)
	if err != nil {
		return err
	}
	defer response.Body.Close()
	if response.StatusCode < 200 || response.StatusCode >= 300 {
		return fmt.Errorf("attachment download failed with status %s", response.Status)
	}
	if _, err := io.Copy(os.Stdout, response.Body); err != nil {
		return err
	}
	return nil
}

func parseListArgs(command string, args []string, requireEntry bool) (listArgs, error) {
	set := newFlagSet(command)
	scope := set.String("scope", "", "inbox, pod, or org")
	scopeID := set.String("scope-id", "", "exact scope ID")
	direction := set.String("direction", "", "send, receive, or reply")
	listType := set.String("type", "", "allow or block")
	entry := set.String("entry", "", "exact email address or domain")
	if err := set.Parse(args); err != nil {
		return listArgs{}, err
	}
	if set.NArg() != 0 {
		return listArgs{}, fmt.Errorf("%s received unexpected positional arguments", command)
	}
	for name, value := range map[string]string{
		"scope":     *scope,
		"scope-id":  *scopeID,
		"direction": *direction,
		"type":      *listType,
	} {
		if err := required(value, name); err != nil {
			return listArgs{}, err
		}
	}
	if requireEntry {
		if err := required(*entry, "entry"); err != nil {
			return listArgs{}, err
		}
	} else if *entry != "" {
		return listArgs{}, errors.New("lists does not accept --entry")
	}
	if *scope != "inbox" && *scope != "pod" && *scope != "org" {
		return listArgs{}, errors.New("--scope must be inbox, pod, or org")
	}
	if *direction != "send" && *direction != "receive" && *direction != "reply" {
		return listArgs{}, errors.New("--direction must be send, receive, or reply")
	}
	if *listType != "allow" && *listType != "block" {
		return listArgs{}, errors.New("--type must be allow or block")
	}
	return listArgs{*scope, *scopeID, *direction, *listType, *entry}, nil
}

func listEntries(ctx context.Context, client *agentmail.Client, args listArgs) error {
	entries := make([]listOutput, 0)
	seen := map[string]bool{}
	pageToken := ""
	for {
		nextToken := ""
		switch args.scope {
		case "inbox":
			query := agentmail.InboxListListParams{
				InboxID: args.scopeID, Direction: agentmail.InboxListListParamsDirection(args.direction),
				Limit: param.NewOpt[int64](100),
			}
			if pageToken != "" {
				query.PageToken = param.NewOpt(pageToken)
			}
			page, err := client.Inboxes.Lists.List(ctx, agentmail.InboxListListParamsType(args.listType), query)
			if err != nil {
				return err
			}
			for _, entry := range page.Entries {
				entries = append(entries, newListOutput(args.scope, args.scopeID, entry.Direction, entry.ListType, entry.Entry, entry.EntryType, entry.ReadOnly, entry.Reason, entry.CreatedAt))
			}
			nextToken = page.NextPageToken
		case "pod":
			query := agentmail.PodListListParams{
				PodID: args.scopeID, Direction: agentmail.PodListListParamsDirection(args.direction),
				Limit: param.NewOpt[int64](100),
			}
			if pageToken != "" {
				query.PageToken = param.NewOpt(pageToken)
			}
			page, err := client.Pods.Lists.List(ctx, agentmail.PodListListParamsType(args.listType), query)
			if err != nil {
				return err
			}
			for _, entry := range page.Entries {
				entries = append(entries, newListOutput(args.scope, args.scopeID, entry.Direction, entry.ListType, entry.Entry, entry.EntryType, entry.ReadOnly, entry.Reason, entry.CreatedAt))
			}
			nextToken = page.NextPageToken
		case "org":
			query := agentmail.ListListParams{Direction: agentmail.ListListParamsDirection(args.direction), Limit: param.NewOpt[int64](100)}
			if pageToken != "" {
				query.PageToken = param.NewOpt(pageToken)
			}
			page, err := client.Lists.List(ctx, agentmail.ListListParamsType(args.listType), query)
			if err != nil {
				return err
			}
			for _, entry := range page.Entries {
				if entry.OrganizationID != args.scopeID {
					return errors.New("organization list response did not match --scope-id")
				}
				entries = append(entries, newListOutput(args.scope, args.scopeID, entry.Direction, entry.ListType, entry.Entry, entry.EntryType, entry.ReadOnly, entry.Reason, entry.CreatedAt))
			}
			nextToken = page.NextPageToken
		}
		if nextToken == "" {
			break
		}
		if seen[nextToken] {
			return errors.New("list pagination returned a repeated page token")
		}
		seen[nextToken] = true
		pageToken = nextToken
	}
	return emit(struct {
		Entries []listOutput `json:"entries"`
	}{entries})
}

func createListEntry(ctx context.Context, client *agentmail.Client, args listArgs) error {
	if err := denyMutationID(args.scopeID); err != nil {
		return err
	}
	if err := denyMutationAddress(args.scopeID); err != nil {
		return err
	}
	if err := denyMutationAddress(args.entry); err != nil {
		return err
	}
	var output listOutput
	switch args.scope {
	case "inbox":
		response, err := client.Inboxes.Lists.New(ctx, agentmail.InboxListNewParamsType(args.listType), agentmail.InboxListNewParams{
			InboxID: args.scopeID, Direction: agentmail.InboxListNewParamsDirection(args.direction), Entry: args.entry,
		})
		if err != nil {
			return err
		}
		output = newListOutput(args.scope, args.scopeID, string(response.Direction), string(response.ListType), response.Entry, string(response.EntryType), response.ReadOnly, response.Reason, response.CreatedAt)
	case "pod":
		response, err := client.Pods.Lists.New(ctx, agentmail.PodListNewParamsType(args.listType), agentmail.PodListNewParams{
			PodID: args.scopeID, Direction: agentmail.PodListNewParamsDirection(args.direction), Entry: args.entry,
		})
		if err != nil {
			return err
		}
		output = newListOutput(args.scope, args.scopeID, string(response.Direction), string(response.ListType), response.Entry, string(response.EntryType), response.ReadOnly, response.Reason, response.CreatedAt)
	case "org":
		response, err := client.Lists.New(ctx, agentmail.ListNewParamsType(args.listType), agentmail.ListNewParams{
			Direction: agentmail.ListNewParamsDirection(args.direction), Entry: args.entry,
		})
		if err != nil {
			return err
		}
		if response.OrganizationID != args.scopeID {
			return errors.New("organization list response did not match --scope-id")
		}
		output = newListOutput(args.scope, args.scopeID, string(response.Direction), string(response.ListType), response.Entry, string(response.EntryType), response.ReadOnly, response.Reason, response.CreatedAt)
	}
	return emit(output)
}

func deleteListEntry(ctx context.Context, client *agentmail.Client, args listArgs) error {
	if err := denyMutationID(args.scopeID); err != nil {
		return err
	}
	if err := denyMutationAddress(args.scopeID); err != nil {
		return err
	}
	if err := denyMutationAddress(args.entry); err != nil {
		return err
	}
	var err error
	switch args.scope {
	case "inbox":
		err = client.Inboxes.Lists.Delete(ctx, args.entry, agentmail.InboxListDeleteParams{
			InboxID: args.scopeID, Direction: agentmail.InboxListDeleteParamsDirection(args.direction), Type: agentmail.InboxListDeleteParamsType(args.listType),
		})
	case "pod":
		err = client.Pods.Lists.Delete(ctx, args.entry, agentmail.PodListDeleteParams{
			PodID: args.scopeID, Direction: agentmail.PodListDeleteParamsDirection(args.direction), Type: agentmail.PodListDeleteParamsType(args.listType),
		})
	case "org":
		err = client.Lists.Delete(ctx, args.entry, agentmail.ListDeleteParams{
			Direction: agentmail.ListDeleteParamsDirection(args.direction), Type: agentmail.ListDeleteParamsType(args.listType),
		})
	}
	if err != nil {
		return err
	}
	return emit(struct {
		Deleted   bool   `json:"deleted"`
		Scope     string `json:"scope"`
		ScopeID   string `json:"scope_id"`
		Direction string `json:"direction"`
		ListType  string `json:"type"`
		Entry     string `json:"entry"`
	}{true, args.scope, args.scopeID, args.direction, args.listType, args.entry})
}
