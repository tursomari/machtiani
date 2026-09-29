"""Run the session script against disposable stubs, without Docker or credentials."""

import os
from pathlib import Path
import pty
import shlex
import shutil
import subprocess
import tempfile
import time


script_dir = Path(__file__).resolve().parent
source = (script_dir / "run-install-evaluation.sh").read_text()
assert "bash --noprofile --norc --login -i" in source, (
    "post-install must use an interactive login shell preserving the session environment"
)


def check(agent_status, verification_status, shell_status):
    with tempfile.TemporaryDirectory(prefix=".ixe-contract-", dir=script_dir) as tmp:
        root = Path(tmp)
        runtime = root / "run"
        runtime.mkdir()
        (runtime / "prepared").touch()
        home = root / "home"
        home.mkdir()
        commands = root / "bin"
        commands.mkdir()

        def stub(name, body):
            path = commands / name
            path.write_text("#!/bin/sh\nset -eu\n" + body + "\n")
            path.chmod(0o700)

        stub("id", "echo 1000")
        stub("script", f'touch "$IXE_TEST_ROOT/run/artifacts/terminal.typescript"\nexit {agent_status}')
        stub("ixe-verify", f'echo verification-fixture\nexit {verification_status}')
        stub("bash", '''test "$*" = '--noprofile --norc --login -i'
test -t 0 && test -t 1 && test -t 2
test "$HOME" = "$IXE_TEST_ROOT/home"
test "$PATH" = "$IXE_TEST_PATH"
test "$NIX_REMOTE" = daemon
test "$NIX_CONFIG" = 'experimental-features = nix-command flakes'
test ! -e "$IXE_TEST_ROOT/run/completed"
touch "$IXE_TEST_ROOT/shell-ready"
read -r finish
test "$finish" = finish
exit "$IXE_TEST_SHELL_STATUS"''')

        # Rewrite only container locations in a disposable copy. The real script
        # still owns status handling and the completion marker's publication.
        test_path = f"{commands}:{os.defpath}"
        adapted = source.replace("/run/ixe", str(runtime))
        adapted = adapted.replace("/home/installer", str(home))
        adapted = adapted.replace("/usr/local/libexec", str(commands))
        adapted = "\n".join(
            f"export PATH={shlex.quote(test_path)}" if line.startswith("export PATH=") else line
            for line in adapted.splitlines()
        )
        session = root / "session.sh"
        session.write_text(adapted + "\n")
        env = dict(os.environ, PATH=test_path, IXE_TEST_ROOT=str(root),
                   IXE_TEST_PATH=test_path, IXE_TEST_SHELL_STATUS=str(shell_status))
        env.pop("BASH_ENV", None)
        master, slave = pty.openpty()
        try:
            with subprocess.Popen(
                [shutil.which("bash"), "--noprofile", "--norc", str(session)],
                stdin=slave, stdout=slave, stderr=slave, env=env,
            ) as process:
                try:
                    if agent_status == verification_status == 0:
                        deadline = time.monotonic() + 5
                        while not (root / "shell-ready").exists():
                            assert process.poll() is None, "session ended before post-install shell"
                            assert time.monotonic() < deadline, "post-install shell did not become ready"
                            time.sleep(0.01)
                        assert process.poll() is None, "session must wait for the operator"
                        for name in ("completed", "artifacts/agent-exit-status",
                                     "artifacts/verification-exit-status"):
                            assert not (runtime / name).exists(), f"published {name} before shell exit"
                        os.write(master, b"finish\n")
                    status = process.wait(timeout=5)
                    assert (status == 0) == (agent_status == verification_status == 0)
                    assert (root / "shell-ready").exists() == (agent_status == verification_status == 0)
                    assert (runtime / "completed").read_text() == (
                        f"agent_status={agent_status}\nverification_status={verification_status}\n"
                    )
                    for name, expected in (("agent", agent_status), ("verification", verification_status)):
                        assert (runtime / f"artifacts/{name}-exit-status").read_text() == f"{expected}\n"
                    assert (runtime / "artifacts/terminal.typescript").exists()
                    assert (runtime / "artifacts/verification.txt").read_text() == "verification-fixture\n"
                finally:
                    if process.poll() is None:
                        process.kill()
                        process.wait()
        finally:
            os.close(master)
            os.close(slave)


for statuses in ((0, 0, 0), (0, 0, 23), (7, 0, 0), (0, 9, 0), (7, 9, 0)):
    check(*statuses)
print("IXE session lifecycle contract test passed (5 cases)")
