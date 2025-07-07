# Makefile for kdump-auto-bisect tool (Modular Framework)

# Installation directories
PREFIX ?= /usr/local
BIN_DIR := $(PREFIX)/bin/kdump-bisect
HANDLER_DIR_TARGET := $(BIN_DIR)/handlers
SERVICE_DIR := /etc/systemd/system
CONFIG_FILE_TARGET := $(BIN_DIR)/bisect.conf

# Source files and directories
SCRIPT_SRC := bisect-kernel.sh
SERVICE_SRC := kdump-bisect.service
CONFIG_SRC := bisect.conf
HANDLER_SRC_DIR := handlers
HANDLER_SRCS := $(wildcard $(HANDLER_SRC_DIR)/*.sh)

.PHONY: all install uninstall clean help

all: help

help:
	@echo "Usage: make [target]"
	@echo ""
	@echo "Targets:"
	@echo "  install      Install the bisection scripts, handlers, and systemd service."
	@echo "  uninstall    Remove all installed files and the service."
	@echo "  help         Show this help message."

install:
	@if [ "$(EUID)" -ne 0 ]; then \
		echo "Please run as root or with sudo."; \
		exit 1; \
	fi
	@echo "Installing kdump-auto-bisect tool (modular)..."
	@echo "Creating directories: $(BIN_DIR) and $(HANDLER_DIR_TARGET)"
	@mkdir -p $(HANDLER_DIR_TARGET)

	@echo "Copying orchestrator script to $(BIN_DIR)/$(SCRIPT_SRC)"
	@cp $(SCRIPT_SRC) $(BIN_DIR)/
	@chmod +x $(BIN_DIR)/$(SCRIPT_SRC)

	@echo "Copying handler scripts to $(HANDLER_DIR_TARGET)/"
	@cp $(HANDLER_SRCS) $(HANDLER_DIR_TARGET)/
	@chmod +x $(HANDLER_DIR_TARGET)/*.sh

	@echo "Copying systemd service to $(SERVICE_DIR)/$(SERVICE_SRC)"
	@cp $(SERVICE_SRC) $(SERVICE_DIR)/

	@echo "Reloading systemd daemon..."
	@systemctl daemon-reload

	@if [ ! -f "$(CONFIG_FILE_TARGET)" ]; then \
		echo "Copying default configuration to $(CONFIG_FILE_TARGET)"; \
		cp $(CONFIG_SRC) $(CONFIG_FILE_TARGET); \
	fi
	@echo ""
	@echo "Installation complete."
	@echo "IMPORTANT: Please edit the configuration file at $(CONFIG_FILE_TARGET) before enabling the service."

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

