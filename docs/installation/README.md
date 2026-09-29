# Installation-agent guidance

`INSTALL.md` is the installation agent's permanent contract and stage map. It
deliberately does not contain the complete procedure. After welcome consent,
the agent reads these numbered stage files in order and loads only the selected
backend guide.

The split serves two goals:

- permanent interaction, safety, and authorization rules remain in context;
- detailed mechanics and backend branches appear only when they are relevant.

Each stage states its goal, authority boundaries, completion conditions, and
single next file. `backend-catalogue.md` records verified shortcuts learned
through development and IXE runs, while requiring the agent to inspect actual
installed CLI behavior. Catalogue absence never rules out a custom adapter.
Stage 5 loads `live-email-progress.md` only after a test email is sent, so
operational inspection detail stays out of the normal installation path. After
the live reply succeeds, Stage 6 owns the final automatic-startup choice. Enabling
it is optional; explaining the reboot-startup outcome is required, including
when the environment cannot support it.

Keep canonical user-facing messages in `INSTALL.md`. Keep general stage
behavior in the numbered files, backend-specific knowledge under `backends/`,
and executable product commands in `../installation-procedure.md`.

Run `tests/install-prompt-test.sh` after changing any of these files.
