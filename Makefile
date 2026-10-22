# Convenience wrapper around install/uninstall scripts
.PHONY: install uninstall enable disable test

install:
	bash ./install.sh

uninstall:
	sudo bash ./uninstall.sh

enable:
	sudo systemctl enable --now pihealth.timer pidash.service pibackup.timer

disable:
	sudo systemctl disable --now pihealth.timer pidash.service pibackup.timer

test:
	python3 -m unittest discover -s tests -v
