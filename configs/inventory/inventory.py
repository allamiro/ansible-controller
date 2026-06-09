#!/usr/bin/env python3
"""
Dynamic inventory script for ansible-controller.

Reads hosts from configs/inventory/hosts.json when it exists, falling back to
the static hosts.ini for day-to-day use. Supports --list and --host flags as
required by Ansible's dynamic inventory protocol.

Usage:
  ansible-playbook -i /configs/inventory/inventory.py site.yml

hosts.json format:
  {
    "all": {
      "hosts": ["192.168.1.10", "192.168.1.11"],
      "vars": { "ansible_user": "ansible" }
    },
    "webservers": {
      "hosts": ["192.168.1.10"],
      "vars": {}
    }
  }
"""

import argparse
import json
import os
import sys

HOSTS_JSON = os.path.join(os.path.dirname(__file__), "hosts.json")


def load_inventory():
    if not os.path.exists(HOSTS_JSON):
        return {
            "_meta": {"hostvars": {}},
            "all": {"hosts": [], "vars": {}},
        }

    with open(HOSTS_JSON) as f:
        raw = json.load(f)

    inventory = {"_meta": {"hostvars": {}}}
    for group, data in raw.items():
        inventory[group] = {
            "hosts": data.get("hosts", []),
            "vars": data.get("vars", {}),
        }
        for host in data.get("hosts", []):
            inventory["_meta"]["hostvars"].setdefault(host, {})

    return inventory


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--list", action="store_true")
    parser.add_argument("--host", metavar="HOST")
    args = parser.parse_args()

    inventory = load_inventory()

    if args.list:
        print(json.dumps(inventory, indent=2))
    elif args.host:
        hostvars = inventory.get("_meta", {}).get("hostvars", {})
        print(json.dumps(hostvars.get(args.host, {}), indent=2))
    else:
        parser.print_help()
        sys.exit(1)


if __name__ == "__main__":
    main()
