// A signed, loopback-only mailbox for the complete native Windows client gate.
// Build from the DearMachine Go module, then run only in the disposable VM.
package main

import (
	"bytes"
	"crypto/ed25519"
	"crypto/rand"
	"crypto/rsa"
	"crypto/tls"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/base64"
	"encoding/json"
	"encoding/pem"
	"fmt"
	"io"
	"log"
	"math/big"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"sync"
	"time"

	"github.com/emersion/go-msgauth/dkim"
	"golang.org/x/net/dns/dnsmessage"
)

func must(err error) {
	if err != nil {
		log.Fatal(err)
	}
}
func main() {
	if runtime.GOOS != "windows" || os.Getenv("COMPUTERNAME") != "DM-WIN-TEST" || len(os.Args) != 3 {
		log.Fatal("usage in disposable DM-WIN-TEST guest: mail-fixture <evidence-directory> <task-text-file>")
	}
	root, err := filepath.Abs(os.Args[1])
	must(err)
	must(os.MkdirAll(root, 0700))
	task, err := os.ReadFile(os.Args[2])
	must(err)
	public, private, err := ed25519.GenerateKey(rand.Reader)
	must(err)
	txt := "v=DKIM1; k=ed25519; p=" + base64.StdEncoding.EncodeToString(public)
	const id = "<windows-task@example.test>"
	const inbox = "windows-fixture@example.test"
	stamp := time.Now().UTC()
	raw := fmt.Sprintf("From: proof-user@example.test\r\nTo: %s\r\nMessage-ID: %s\r\nSubject: Windows file task\r\nDate: %s\r\nMIME-Version: 1.0\r\nContent-Type: text/plain; charset=utf-8\r\n\r\n%s\r\n", inbox, id, stamp.Format(time.RFC1123Z), strings.TrimSpace(string(task)))
	var signed bytes.Buffer
	must(dkim.Sign(&signed, strings.NewReader(raw), &dkim.SignOptions{Domain: "example.test", Selector: "windows", Signer: private}))
	must(os.WriteFile(filepath.Join(root, "signed-message.eml"), signed.Bytes(), 0600))
	certificate := &x509.Certificate{SerialNumber: big.NewInt(stamp.UnixNano()), Subject: pkix.Name{CommonName: "Dear Machine disposable Windows fixture"}, NotBefore: stamp.Add(-time.Hour), NotAfter: stamp.Add(48 * time.Hour), DNSNames: []string{"localhost"}, IPAddresses: []net.IP{net.ParseIP("127.0.0.1")}, KeyUsage: x509.KeyUsageDigitalSignature | x509.KeyUsageCertSign, ExtKeyUsage: []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth}, BasicConstraintsValid: true, IsCA: true}
	tlsPrivate, err := rsa.GenerateKey(rand.Reader, 2048)
	must(err)
	der, err := x509.CreateCertificate(rand.Reader, certificate, certificate, &tlsPrivate.PublicKey, tlsPrivate)
	must(err)
	certPEM := pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: der})
	must(os.WriteFile(filepath.Join(root, "fixture-ca.pem"), certPEM, 0600))
	keyDER, err := x509.MarshalPKCS8PrivateKey(tlsPrivate)
	must(err)
	pair, err := tls.X509KeyPair(certPEM, pem.EncodeToMemory(&pem.Block{Type: "PRIVATE KEY", Bytes: keyDER}))
	must(err)
	secure, err := tls.Listen("tcp", "127.0.0.1:58750", &tls.Config{Certificates: []tls.Certificate{pair}, MinVersion: tls.VersionTLS12})
	must(err)
	go func() {
		must(http.Serve(secure, http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			if r.URL.Path != "/raw" || r.Method != "GET" {
				http.NotFound(w, r)
				return
			}
			w.Write(signed.Bytes())
		})))
	}()
	dns, err := net.ListenPacket("udp", "127.0.0.1:53")
	must(err)
	go func() {
		for {
			buffer := make([]byte, 4096)
			n, peer, err := dns.ReadFrom(buffer)
			if err != nil {
				return
			}
			packet := append([]byte{}, buffer[:n]...)
			go dnsReply(dns, peer, packet, txt)
		}
	}()
	var mu sync.Mutex
	unread := true
	var replies []map[string]any
	requests, err := os.OpenFile(filepath.Join(root, "requests.jsonl"), os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0600)
	must(err)
	defer requests.Close()
	message := func() map[string]any {
		labels := []string{"read"}
		if unread {
			labels = []string{"unread"}
		}
		return map[string]any{"message_id": id, "thread_id": "windows-thread", "inbox_id": inbox, "from": "proof-user@example.test", "to": []string{inbox}, "subject": "Windows file task", "text": strings.TrimSpace(string(task)), "extracted_text": strings.TrimSpace(string(task)), "timestamp": stamp.Format(time.RFC3339), "created_at": stamp.Format(time.RFC3339), "labels": labels}
	}
	handler := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		mu.Lock()
		defer mu.Unlock()
		json.NewEncoder(requests).Encode(map[string]any{"method": r.Method, "path": r.URL.Path, "at": time.Now().UTC()})
		w.Header().Set("Content-Type", "application/json")
		answer := func(v any) { json.NewEncoder(w).Encode(v) }
		prefix := "/v0/inboxes/" + inbox
		path := strings.TrimPrefix(r.URL.Path, prefix)
		switch {
		case r.Method == "GET" && (path == "/lists/receive/allow/proof-user@example.test" || path == "/lists/reply/allow/proof-user@example.test" || path == "/lists/send/allow/proof-user@example.test"):
			answer(map[string]any{"entry": "proof-user@example.test", "list_type": "allow", "entry_type": "email", "inbox_id": inbox, "read_only": true, "direction": strings.Split(path, "/")[2]})
		case path == "/messages" && r.Method == "GET":
			values := []map[string]any{}
			if _, err := os.Stat(filepath.Join(root, "deliver")); err == nil {
				if unread || !strings.Contains(r.URL.RawQuery, "unread") {
					values = append(values, message())
				}
			}
			answer(map[string]any{"count": len(values), "messages": values})
		case path == "/messages/"+id && r.Method == "GET":
			answer(message())
		case path == "/messages/"+id+"/raw" && r.Method == "GET":
			answer(map[string]any{"message_id": id, "size": signed.Len(), "download_url": "https://localhost:58750/raw"})
		case path == "/threads/windows-thread" && r.Method == "GET":
			answer(map[string]any{"thread_id": "windows-thread", "messages": append([]map[string]any{message()}, replies...)})
		case path == "/messages/"+id && r.Method == "PATCH":
			unread = false
			answer(message())
		case path == "/messages/"+id+"/reply" && r.Method == "POST":
			data, err := io.ReadAll(io.LimitReader(r.Body, 4<<20))
			if err != nil {
				http.Error(w, "read", 400)
				return
			}
			var reply map[string]any
			if json.Unmarshal(data, &reply) != nil {
				http.Error(w, "json", 400)
				return
			}
			// Recorded locally; there is no outbound mail implementation.
			must(os.WriteFile(filepath.Join(root, fmt.Sprintf("reply-%d.json", len(replies)+1)), data, 0600))
			replyID := fmt.Sprintf("<reply-%d@example.test>", len(replies)+1)
			replies = append(replies, map[string]any{"message_id": replyID, "thread_id": "windows-thread", "in_reply_to": id, "from": inbox, "to": []string{"proof-user@example.test"}, "text": reply["text"], "labels": []string{"sent"}, "timestamp": time.Now().UTC().Format(time.RFC3339)})
			answer(map[string]any{"message_id": replyID, "thread_id": "windows-thread"})
		default:
			http.Error(w, "unsupported fixture operation", 404)
		}
	})
	must(os.WriteFile(filepath.Join(root, "ready"), []byte("ready"), 0600))
	fmt.Println("LOOPBACK_MAIL_FIXTURE_READY")
	must(http.ListenAndServe("127.0.0.1:58749", handler))
}
func dnsReply(socket net.PacketConn, peer net.Addr, packet []byte, txt string) {
	var request dnsmessage.Message
	if request.Unpack(packet) != nil || len(request.Questions) != 1 {
		return
	}
	question := request.Questions[0]
	if strings.EqualFold(question.Name.String(), "windows._domainkey.example.test.") && question.Type == dnsmessage.TypeTXT {
		response := dnsmessage.Message{Header: dnsmessage.Header{ID: request.Header.ID, Response: true, Authoritative: true, RecursionDesired: request.Header.RecursionDesired, RecursionAvailable: true}, Questions: request.Questions, Answers: []dnsmessage.Resource{{Header: dnsmessage.ResourceHeader{Name: question.Name, Type: dnsmessage.TypeTXT, Class: dnsmessage.ClassINET, TTL: 30}, Body: &dnsmessage.TXTResource{TXT: []string{txt}}}}}
		if data, err := response.Pack(); err == nil {
			socket.WriteTo(data, peer)
		}
		return
	}
	upstream, err := net.DialTimeout("udp", "10.0.2.3:53", 3*time.Second)
	if err != nil {
		return
	}
	defer upstream.Close()
	upstream.SetDeadline(time.Now().Add(3 * time.Second))
	if _, err = upstream.Write(packet); err != nil {
		return
	}
	buffer := make([]byte, 4096)
	if n, err := upstream.Read(buffer); err == nil {
		socket.WriteTo(buffer[:n], peer)
	}
}
