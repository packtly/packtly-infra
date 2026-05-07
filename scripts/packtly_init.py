#!/usr/bin/env python3

import yaml
import os
import tempfile
import subprocess
from dataclasses import dataclass
import typer
from typing import Optional

app = typer.Typer()

INVENTORY_DIR : str = "inventories"

@dataclass
class Config:
    """Configuration data collected from user input"""
    env_name: str
    deploy_host: str
    is_local: bool
    ansible_user: str

    container_registry_auth: bool
    container_registry_username: Optional[str]
    container_registry_url: Optional[str]
    container_registry_password: Optional[str]

    container_method: str
    container_force_rebuild: bool
    container_registry: str
    container_image_local: str

    service_user: str
    container_name: str
    datadir: str
    datadir_recreate: bool

    web_port: int
    ssh_port: int
    app_name: str

    gpg_user: str
    gpg_email: str
    api_user: str

    become_pass: str
    gpg_pass: str
    api_pass: str


def ask(prompt: str, default: Optional[str] = None, secret: bool = False) -> str:
    """
    Ask a question and return the answer, with optional
    default and secret input
    """
    if secret:
        return typer.prompt(prompt, hide_input=True)

    if default is not None:
        return typer.prompt(prompt, default=default)
    return typer.prompt(prompt)


def ask_bool(prompt: str, default: bool = False) -> bool:
    """Ask a yes/no question and return a boolean"""
    return typer.confirm(prompt, default=default)


def collect_config() -> Config:
    """Collect configuration values from user input"""
    env_name = ask("Environment name", "dev")
    typer.echo(f"== Packtly Infra Init: {env_name} ==")

    deploy_host = ask("Server hostname or IP", "localhost")

    if deploy_host == "localhost":
        is_local = True
        ansible_user = os.getenv("USER", "")
    else:
        is_local = False
        ansible_user = ask("Ansible SSH user", "deploy")

    registry_auth = ask_bool("Authenticate to container registry", False)
    registry_username = (
        ask("Container registry username", "user") if registry_auth else None
    )
    registry_url = ask("Container registry URL", "xxx") if registry_auth else None
    registry_password = (
        ask("Container registry password", secret=True) if registry_auth else None
    )

    return Config(
        env_name=env_name,
        deploy_host=deploy_host,
        is_local=is_local,
        ansible_user=ansible_user,
        container_registry_auth=registry_auth,
        container_registry_username=registry_username,
        container_registry_url=registry_url,
        container_registry_password=registry_password,
        container_method=ask("Container method (build/pull)", "pull"),
        container_force_rebuild=ask_bool("Force rebuild", False),
        container_registry=ask("Container registry image source", "ghcr.io/packtly/packtly-infra:latest"),
        container_image_local=ask(
            "Local container image", "packtly-infra:dev"
        ),
        service_user=ask("Service user", "packtly"),
        container_name=ask("Container name", "packtly"),
        datadir=ask("Data volume name", "packtly_data"),
        datadir_recreate=ask_bool("Recreate data dir", True),
        web_port=int(ask("Web port", "8080")),
        ssh_port=int(ask("SSH port", "2222")),
        app_name=ask("App name", "packtly"),
        gpg_user=ask("GPG user", "packtly"),
        gpg_email=ask("GPG email", "user@example.com"),
        api_user=ask("API user", "admin"),
        become_pass=ask("Sudo become password", secret=True),
        gpg_pass=ask("GPG passphrase", secret=True),
        api_pass=ask("API password", secret=True),
    )


def write_inventory(cfg: Config, inventories_dir=INVENTORY_DIR):
    """Write Ansible inventory file based on config"""
    os.makedirs(inventories_dir, exist_ok=True)
    hosts_file = os.path.join(inventories_dir, "hosts.yml")

    if os.path.exists(hosts_file):
        with open(hosts_file, encoding="utf-8") as f:
            inventory = yaml.safe_load(f) or {}
    else:
        inventory = {}

    inventory.setdefault("all", {}).setdefault("children", {})

    if cfg.is_local:
        host_vars = {
            "ansible_connection": "local",
            "ansible_python_interpreter": "/usr/bin/python3",
        }
    else:
        host_vars = {
            "ansible_connection": "ssh",
            "ansible_host": cfg.deploy_host,
            "bootstrap_user": cfg.ansible_user,
        }

    inventory["all"]["children"][cfg.env_name] = {"hosts": {cfg.deploy_host: host_vars}}

    with open(hosts_file, "w", encoding="utf-8") as f:
        yaml.safe_dump(inventory, f, sort_keys=False)

    return hosts_file


def write_group_vars(cfg: Config, inventories_dir=INVENTORY_DIR):
    """Write group_vars file based on config"""
    group_vars_dir = os.path.join(inventories_dir, "group_vars", cfg.env_name)
    os.makedirs(group_vars_dir, exist_ok=True)

    local_file = os.path.join(group_vars_dir, "local.yml")

    local_data = {
        "container_registry_auth": cfg.container_registry_auth,
        "container_registry_username": cfg.container_registry_username,
        "container_registry_url": cfg.container_registry_url,
        "container_method": cfg.container_method,
        "container_force_rebuild": cfg.container_force_rebuild,
        "container_registry": cfg.container_registry,
        "container_image_local": cfg.container_image_local,
        "service_user": cfg.service_user,
        "container_name": cfg.container_name,
        "datadir": cfg.datadir,
        "datadir_recreate": cfg.datadir_recreate,
        "web_port": cfg.web_port,
        "ssh_port": cfg.ssh_port,
        "app_name": cfg.app_name,
        "gpg_user": cfg.gpg_user,
        "gpg_email": cfg.gpg_email,
        "api_user": cfg.api_user,
    }

    with open(local_file, "w", encoding="utf-8") as f:
        yaml.safe_dump(local_data, f, sort_keys=False)

    return group_vars_dir, local_file


def write_vault(cfg: Config, group_vars_dir):
    """Write Ansible vault file based on config and encrypt it"""
    vault_file = os.path.join(group_vars_dir, "vault.yml")

    vault_data = {
        "ansible_become_password": cfg.become_pass,
        "gpg_pass": cfg.gpg_pass,
        "api_pass": cfg.api_pass,
        "vault_container_registry_password": cfg.container_registry_password,
    }

    with tempfile.NamedTemporaryFile("w", delete=False, encoding="utf-8") as tmp:
        yaml.safe_dump(vault_data, tmp, sort_keys=False)
        tmp_path = tmp.name

    typer.echo("Encrypting vault file...")

    subprocess.run(
        [
            "ansible-vault",
            "encrypt",
            "--output",
            vault_file,
            tmp_path,
        ],
        check=True,
    )

    os.unlink(tmp_path)
    return vault_file


@app.command()
def init():
    """Initialize a new Packtly environment"""
    cfg = collect_config()

    hosts_file = write_inventory(cfg)
    group_vars_dir, local_file = write_group_vars(cfg)
    vault_file = write_vault(cfg, group_vars_dir)

    typer.echo("\nDone. Files created:")
    typer.echo(f"  {hosts_file}")
    typer.echo(f"  {local_file}")
    typer.echo(f"  {vault_file}")

    typer.echo("\nRun deployment with:")
    typer.echo(f"  ./scripts/deploy {cfg.env_name}")


if __name__ == "__main__":
    app()
