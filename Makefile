.PHONY: syntax

syntax:
	ansible-playbook --syntax-check playbooks/site.yml
	ansible-playbook --syntax-check playbooks/configure.yml
	ansible-playbook --syntax-check playbooks/realms.yml
	ansible-playbook --syntax-check playbooks/update.yml
	ansible-playbook --syntax-check playbooks/rollback.yml
	ansible-playbook --syntax-check playbooks/status.yml
	ansible-playbook --syntax-check playbooks/loadbalancer.yml
