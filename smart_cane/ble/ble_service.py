#!/usr/bin/env python3

import os
import json
import subprocess

import dbus
import dbus.service
import dbus.mainloop.glib

from gi.repository import GLib


# =========================================================
# BLE settings
# =========================================================

BLUEZ_SERVICE_NAME = "org.bluez"

GATT_MANAGER_IFACE = "org.bluez.GattManager1"
GATT_SERVICE_IFACE = "org.bluez.GattService1"
GATT_CHRC_IFACE = "org.bluez.GattCharacteristic1"

DBUS_OM_IFACE = "org.freedesktop.DBus.ObjectManager"
DBUS_PROP_IFACE = "org.freedesktop.DBus.Properties"

SERVICE_UUID = "12345678-1234-5678-1234-56789abcdef0"
CHAR_UUID = "12345678-1234-5678-1234-56789abcdef1"


# =========================================================
# Global state
# =========================================================

smartcane_characteristic = None

# Function executed when a command is received from the app.
command_callback = None


# =========================================================
# Command callback
# =========================================================

def set_command_callback(callback):
    """
    Register a function that will receive BLE commands.

    Example:

        def handle_command(command):
            print(command)

        set_command_callback(handle_command)
    """

    global command_callback

    command_callback = callback


def handle_received_command(text):
    text = text.strip()

    print("")
    print("================================")
    print("[APP -> PI]")
    print(text)
    print("================================")

    # Basic BLE connection test
    if text.upper() == "PING":
        send_text("PONG FROM PI")
        return

    # Pass all other commands to the main program
    if command_callback is not None:
        command_callback(text)
    else:
        print("[BLE] No command callback registered")


# =========================================================
# BLE GATT Application
# =========================================================

class Application(dbus.service.Object):

    def __init__(self, bus):
        self.path = "/"
        self.services = []

        dbus.service.Object.__init__(
            self,
            bus,
            self.path
        )

        self.add_service(
            SmartCaneService(
                bus,
                0
            )
        )

    def get_path(self):
        return dbus.ObjectPath(
            self.path
        )

    def add_service(self, service):
        self.services.append(
            service
        )

    @dbus.service.method(
        DBUS_OM_IFACE,
        out_signature="a{oa{sa{sv}}}"
    )
    def GetManagedObjects(self):
        response = {}

        for service in self.services:

            response[
                service.get_path()
            ] = service.get_properties()

            for characteristic in service.characteristics:

                response[
                    characteristic.get_path()
                ] = characteristic.get_properties()

        return response


# =========================================================
# BLE Service
# =========================================================

class Service(dbus.service.Object):

    PATH_BASE = "/org/bluez/example/service"

    def __init__(
        self,
        bus,
        index,
        uuid,
        primary
    ):
        self.path = (
            self.PATH_BASE
            + str(index)
        )

        self.bus = bus
        self.uuid = uuid
        self.primary = primary
        self.characteristics = []

        dbus.service.Object.__init__(
            self,
            bus,
            self.path
        )

    def get_properties(self):
        return {
            GATT_SERVICE_IFACE: {
                "UUID": self.uuid,
                "Primary": self.primary,
                "Characteristics": dbus.Array(
                    self.get_characteristic_paths(),
                    signature="o"
                )
            }
        }

    def get_path(self):
        return dbus.ObjectPath(
            self.path
        )

    def add_characteristic(
        self,
        characteristic
    ):
        self.characteristics.append(
            characteristic
        )

    def get_characteristic_paths(self):
        return [
            characteristic.get_path()
            for characteristic
            in self.characteristics
        ]

    @dbus.service.method(
        DBUS_PROP_IFACE,
        in_signature="s",
        out_signature="a{sv}"
    )
    def GetAll(
        self,
        interface
    ):
        if interface != GATT_SERVICE_IFACE:
            raise Exception(
                "Invalid interface"
            )

        return self.get_properties()[
            GATT_SERVICE_IFACE
        ]


# =========================================================
# BLE Characteristic
# =========================================================

class Characteristic(dbus.service.Object):

    def __init__(
        self,
        bus,
        index,
        uuid,
        flags,
        service
    ):
        self.path = (
            service.path
            + "/char"
            + str(index)
        )

        self.bus = bus
        self.uuid = uuid
        self.service = service
        self.flags = flags

        self.notifying = False

        self.value = list(
            "READY".encode(
                "utf-8"
            )
        )

        dbus.service.Object.__init__(
            self,
            bus,
            self.path
        )

    def get_properties(self):
        return {
            GATT_CHRC_IFACE: {
                "Service": self.service.get_path(),
                "UUID": self.uuid,
                "Flags": self.flags
            }
        }

    def get_path(self):
        return dbus.ObjectPath(
            self.path
        )

    @dbus.service.method(
        DBUS_PROP_IFACE,
        in_signature="s",
        out_signature="a{sv}"
    )
    def GetAll(
        self,
        interface
    ):
        if interface != GATT_CHRC_IFACE:
            raise Exception(
                "Invalid interface"
            )

        return self.get_properties()[
            GATT_CHRC_IFACE
        ]

    # -----------------------------------------------------
    # Notify signal
    # -----------------------------------------------------

    @dbus.service.signal(
        DBUS_PROP_IFACE,
        signature="sa{sv}as"
    )
    def PropertiesChanged(
        self,
        interface,
        changed,
        invalidated
    ):
        pass

    # -----------------------------------------------------
    # Receive data from app
    # -----------------------------------------------------

    @dbus.service.method(
        GATT_CHRC_IFACE,
        in_signature="aya{sv}"
    )
    def WriteValue(
        self,
        value,
        options
    ):
        raw_bytes = bytes(
            value
        )

        try:
            text = raw_bytes.decode(
                "utf-8"
            )

        except UnicodeDecodeError:
            text = str(
                raw_bytes
            )

        print("")
        print("================================")
        print("BLE Received")
        print("--------------------------------")
        print("Raw :", raw_bytes)
        print("Text:", text)
        print("================================")

        handle_received_command(
            text
        )

    # -----------------------------------------------------
    # Read data from app
    # -----------------------------------------------------

    @dbus.service.method(
        GATT_CHRC_IFACE,
        in_signature="a{sv}",
        out_signature="ay"
    )
    def ReadValue(
        self,
        options
    ):
        return dbus.Array(
            self.value,
            signature="y"
        )

    # -----------------------------------------------------
    # Start Notify
    # -----------------------------------------------------

    @dbus.service.method(
        GATT_CHRC_IFACE
    )
    def StartNotify(self):

        if self.notifying:
            return

        self.notifying = True

        print("")
        print(
            "[BLE] Notify enabled by App"
        )

        self.send_text(
            "HELLO FROM PI"
        )

    # -----------------------------------------------------
    # Stop Notify
    # -----------------------------------------------------

    @dbus.service.method(
        GATT_CHRC_IFACE
    )
    def StopNotify(self):

        self.notifying = False

        print("")
        print(
            "[BLE] Notify disabled by App"
        )

    # -----------------------------------------------------
    # Send text
    # -----------------------------------------------------

    def send_text(
        self,
        message
    ):
        self.value = list(
            message.encode(
                "utf-8"
            )
        )

        print("")
        print("================================")
        print("[PI -> APP]")
        print(message)
        print("================================")

        if not self.notifying:

            print(
                "[BLE] Notify is not enabled yet"
            )

            return False

        self.PropertiesChanged(
            GATT_CHRC_IFACE,
            {
                "Value": dbus.Array(
                    self.value,
                    signature="y"
                )
            },
            []
        )

        return True

    # -----------------------------------------------------
    # Send JSON
    # -----------------------------------------------------

    def send_json(
        self,
        data
    ):
        message = json.dumps(
            data,
            ensure_ascii=False,
            separators=(
                ",",
                ":"
            )
        )

        return self.send_text(
            message
        )


# =========================================================
# SmartCane Service
# =========================================================

class SmartCaneService(Service):

    def __init__(
        self,
        bus,
        index
    ):
        Service.__init__(
            self,
            bus,
            index,
            SERVICE_UUID,
            True
        )

        self.add_characteristic(
            SmartCaneCharacteristic(
                bus,
                0,
                self
            )
        )


# =========================================================
# SmartCane Characteristic
# =========================================================

class SmartCaneCharacteristic(
    Characteristic
):

    def __init__(
        self,
        bus,
        index,
        service
    ):
        global smartcane_characteristic

        Characteristic.__init__(
            self,
            bus,
            index,
            CHAR_UUID,
            [
                "read",
                "write",
                "write-without-response",
                "notify"
            ],
            service
        )

        smartcane_characteristic = self


# =========================================================
# Bluetooth controller setup
# =========================================================

def setup_bluetooth_controller():

    commands = [
        [
            "btmgmt",
            "connectable",
            "on"
        ],
        [
            "btmgmt",
            "advertising",
            "on"
        ],
        [
            "btmgmt",
            "discov",
            "on"
        ],
    ]

    prefix = (
        []
        if os.geteuid() == 0
        else ["sudo"]
    )

    print("")
    print("================================")
    print(" Bluetooth controller setup")
    print("================================")

    for command in commands:

        full_command = (
            prefix
            + command
        )

        result = subprocess.run(
            full_command,
            capture_output=True,
            text=True,
            timeout=10,
            check=False
        )

        if result.returncode != 0:

            message = (
                result.stderr.strip()
                or result.stdout.strip()
                or "unknown error"
            )

            raise RuntimeError(
                "Bluetooth setup failed: "
                + " ".join(
                    full_command
                )
                + " -> "
                + message
            )

        output = (
            result.stdout.strip()
            or result.stderr.strip()
        )

        print(
            "[BLE]",
            " ".join(
                command[1:]
            ),
            "OK",
            (
                "- " + output
                if output
                else ""
            )
        )

    print(
        "[BLE] Controller setup complete"
    )


# =========================================================
# BLE initialization
# =========================================================

def initialize_ble():

    dbus.mainloop.glib.DBusGMainLoop(
        set_as_default=True
    )

    bus = dbus.SystemBus()

    adapter = bus.get_object(
        BLUEZ_SERVICE_NAME,
        "/org/bluez/hci0"
    )

    service_manager = dbus.Interface(
        adapter,
        GATT_MANAGER_IFACE
    )

    app = Application(
        bus
    )

    registration_state = {
        "done": False,
        "success": False
    }

    def register_success():

        registration_state[
            "done"
        ] = True

        registration_state[
            "success"
        ] = True

        print("")
        print("================================")
        print(" SmartCane BLE ready")
        print("================================")

        print("Service UUID:")
        print(SERVICE_UUID)

        print("")

        print("Characteristic UUID:")
        print(CHAR_UUID)

        print("")

        print(
            "Waiting for App connection..."
        )

        print("")

    def register_error(
        error
    ):

        registration_state[
            "done"
        ] = True

        print("")
        print(
            "[BLE] Registration failed"
        )

        print(
            error
        )

    print("")
    print(
        "[BLE] Registering GATT application..."
    )

    service_manager.RegisterApplication(
        app.get_path(),
        {},
        reply_handler=register_success,
        error_handler=register_error
    )

    context = (
        GLib.MainContext.default()
    )

    while not registration_state[
        "done"
    ]:
        context.iteration(
            True
        )

    if not registration_state[
        "success"
    ]:
        raise RuntimeError(
            "BLE registration failed"
        )

    return (
        bus,
        app,
        context
    )


# =========================================================
# BLE helper functions
# =========================================================

def send_text(
    message
):
    if smartcane_characteristic is None:

        print(
            "[BLE] Characteristic not initialized"
        )

        return False

    return smartcane_characteristic.send_text(
        message
    )


def send_json(
    data
):
    if smartcane_characteristic is None:

        print(
            "[BLE] Characteristic not initialized"
        )

        return False

    return smartcane_characteristic.send_json(
        data
    )


def is_connected():
    if smartcane_characteristic is None:
        return False

    return smartcane_characteristic.notifying


def process_ble_events(
    glib_context
):
    while glib_context.pending():

        glib_context.iteration(
            False
        )