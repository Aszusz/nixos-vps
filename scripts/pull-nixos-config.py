import os
import shutil
import subprocess


repo = "git@github.com:Aszusz/nixos-vps.git"
target = "/etc/nixos"
git = os.environ.get("GIT", "git")
ssh = os.environ.get("SSH", "ssh")
ssh_command = f"{ssh} -i /root/.ssh/nixos-vps_deploy -o IdentitiesOnly=yes"


def run(args):
    subprocess.run(args, check=True)


if os.path.isdir(os.path.join(target, ".git")):
    run([git, "-c", f"core.sshCommand={ssh_command}", "-C", target, "fetch", "origin", "main"])
    run([git, "-C", target, "reset", "--hard", "origin/main"])
else:
    shutil.rmtree(target, ignore_errors=True)
    run([git, "-c", f"core.sshCommand={ssh_command}", "clone", "--branch", "main", repo, target])
