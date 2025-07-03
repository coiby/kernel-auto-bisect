# Makefile for kdump-auto-bisect tool

# Installation directories
PREFIX ?= /usr/local
BIN_DIR := $(PREFIX)/bin/kdump-bisect
SERVICE_DIR := /etc/systemd/system
CONFIG_FILE := $(BIN_DIR)/bisect.conf

# Source files
SCRIPT_SRC := bisect-kernel.sh
SERVICE_SRC := kdump-bisect.service
CONFIG_SRC := bisect.conf

.PHONY: all install uninstall clean help

all: help

help:
	@echo "Usage: make [target]"
	@echo ""
	@echo "Targets:"
	@echo "  install      Install the bisection scripts and systemd service."
	@echo "  uninstall    Remove the installed files and service."
	@echo "  clean        Remove temporary files (not currently used)."
	@echo "  help         Show this help message."

install:
	@if [ "$(EUID)" -ne 0 ]; then \
		echo "Please run as root or with sudo."; \
		exit 1; \
	fi
	@echo "Installing kdump-auto-bisect tool..."
	@echo "Creating directory: $(BIN_DIR)"
	@mkdir -p $(BIN_DIR)
	@echo "Copying script to $(BIN_DIR)/$(SCRIPT_SRC)"
	@cp $(SCRIPT_SRC) $(BIN_DIR)/
	@chmod +x $(BIN_DIR)/$(SCRIPT_SRC)
	@echo "Copying systemd service to $(SERVICE_DIR)/$(SERVICE_SRC)"
	@cp $(SERVICE_SRC) $(SERVICE_DIR)/
	@echo "Reloading systemd daemon..."
	@systemctl daemon-reload
	@if [ ! -f "$(CONFIG_FILE)" ]; then \
		echo "Copying default configuration to $(CONFIG_FILE)"; \
		cp $(CONFIG_SRC) $(CONFIG_FILE); \
	fi
	@echo ""
	@echo "Installation complete."
	@echo "IMPORTANT: Please edit the configuration file at $(CONFIG_FILE) before starting."

uninstall:
	@if [ "$(EUID)" -ne 0 ]; then \
		echo "Please run as root or with sudo."; \
		exit 1; \
	fi
	@echo "Uninstalling kdump-auto-bisect tool..."
	@echo "Disabling and stopping service..."
	@systemctl disable --now $(SERVICE_SRC) || true
	@echo "Removing systemd service file: $(SERVICE_DIR)/$(SERVICE_SRC)"
	@rm -f $(SERVICE_DIR)/$(SERVICE_SRC)
	@echo "Reloading systemd daemon..."
	@systemctl daemon-reload
	@echo "Removing script directory: $(BIN_DIR)"
	@rm -rf $(BIN_DIR)
	@echo ""
	@echo "Uninstallation complete."
	@echo "Note: State directories like /var/local/kdump-bisect and the fake RPM repo are not removed."

clean:
	@echo "Nothing to clean."

