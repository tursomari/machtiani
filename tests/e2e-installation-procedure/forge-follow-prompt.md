Treat this environment as a fresh user checkout of the published Installation Procedure appended verbatim below.

Follow the Installation Procedure in order using its documented commands. Documented alternatives, including a scripted non-interactive form that the runbook explicitly describes, are allowed.

Do not inspect `tests/e2e-installation-procedure`, Docker or image-build definitions, harness scripts, or hidden state for answers.

Report every ambiguity, missing prerequisite, inaccurate instruction, workaround, deviation, and blocked stage. Do not ask an outer test harness to repair commands or prerequisites.

Never print, read back, or copy credentials into commands, reports, transcripts, or commits. Use credentials only through their documented environment or private-file interfaces.

Do not modify the documentation or test harness.

Leave the DearMachine client running after setup while returning control to the supervisor.

<!-- RUNTIME_PREREQUISITES_APPEND -->

End stdout with exactly one report in this form. The two delimiter lines are reserved for that final report: do not quote, restate, or emit either delimiter while planning or reporting progress, and do not add a preamble before the final report.

BEGIN_INSTALLATION_PROCEDURE_REPORT
# Installation Procedure report
## Feedback
A short account of documentation feedback.
## Deviations
A short account of deviations, or `None`.
## Final state
A short account of the final state.
## Outcome
Write exactly `SUCCESS` or `FAILED` on its own line.
On the next line, explain the outcome in one sentence.
END_INSTALLATION_PROCEDURE_REPORT

<!-- RUNBOOK_APPEND -->
