#!/usr/bin/env python3

import os
import json
import time
import struct
import subprocess
from pathlib import Path
from subprocess import check_output, CalledProcessError

import cv2
import smbus2
import dbus
import dbus.service
import dbus.mainloop.glib

from gi.repository import GLib
from gpiozero import Button
import digitalio
import adafruit_vl53l1x
from picamera2 import Picamera2
from ultralytics import YOLO

import board
import busio
from adafruit_pca9685 import PCA9685


# =========================================================
# Feature switches
# =========================================================

USE_CAMERA = True
USE_YOLO = True
USE_MOTOR = True
USE_X120X = True
USE_TOF = True

SHOW_CAMERA_WINDOW = True


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
# YOLO / Camera settings
# =========================================================

WIDTH = 640
HEIGHT = 640

YOLO_MODEL_PATH = "yolov8n.pt"
CONFIDENCE_THRESHOLD = 0.35


# =========================================================
# Motor settings
# PCA9685 channels:
# CH0 = TOP
# CH1 = LEFT
# CH2 = BOTTOM
# CH3 = RIGHT
# =========================================================

PCA9685_FREQUENCY = 1000

MOTOR_TOP = 0
MOTOR_LEFT = 1
MOTOR_BOTTOM = 2
MOTOR_RIGHT = 3

MOTOR_STRENGTH_PERCENT = 30
MOTOR_UPDATE_INTERVAL = 0.25

DIRECTION_TO_CHANNELS = {
    "TOP": [MOTOR_TOP],
    "LEFT": [MOTOR_LEFT],
    "BOTTOM": [MOTOR_BOTTOM],
    "RIGHT": [MOTOR_RIGHT],

    "TOP+LEFT": [MOTOR_TOP, MOTOR_LEFT],
    "TOP+RIGHT": [MOTOR_TOP, MOTOR_RIGHT],
    "BOTTOM+LEFT": [MOTOR_BOTTOM, MOTOR_LEFT],
    "BOTTOM+RIGHT": [MOTOR_BOTTOM, MOTOR_RIGHT],

    # Target aligned near the center.
    # A short pulse on all four motors is used as an alignment signal.
    "CENTER": [
        MOTOR_TOP,
        MOTOR_LEFT,
        MOTOR_BOTTOM,
        MOTOR_RIGHT
    ],
}



# =========================================================
# ToF settings - 8 x VL53L1X
# =========================================================

TOF_ADDRESSES = [
    0x2A,
    0x2B,
    0x2C,
    0x2D,
    0x2E,
    0x2F,
    0x30,
    0x31,
]

TOF_XSHUT_PINS = [
    board.D17,
    board.D27,
    board.D22,
    board.D23,
    board.D24,
    board.D25,
    board.D5,
    board.D26,
]

TOF_DISTANCE_MODE = 2
TOF_TIMING_BUDGET_MS = 100

TOF_READ_INTERVAL_SEC = 0.10
TOF_PRINT_INTERVAL_SEC = 0.50
TOF_BLE_INTERVAL_SEC = 0.50

# Recovery settings
TOF_MAX_CONSECUTIVE_ERRORS = 5
TOF_RECOVERY_COOLDOWN_SEC = 2.0
TOF_RECOVERY_SETTLE_SEC = 1.0

tof_i2c = None
tof_xshut = []
tof_sensors = []
tof_last_values = [None] * 8
tof_error_counts = [0] * 8
tof_recovery_requested = False
tof_recovering = False
tof_last_recovery_time = 0.0


# =========================================================
# X120x / status settings
# =========================================================

X120X_ADDRESS = 0x36
PLD_PIN = 6
STATUS_INTERVAL_SEC = 5

x120x_bus = None
pld_button = None


# =========================================================
# Global state
# =========================================================

target_class = None
searching = False

smartcane_characteristic = None

pca = None
motor_i2c = None
shared_i2c = None
last_motor_direction = None
last_motor_update_time = 0.0


# =========================================================
# Utility
# =========================================================

def safe_round(value, digits):
    if value is None:
        return None
    return round(value, digits)


# =========================================================
# Search state
# =========================================================

def set_target(new_target):
    global target_class
    global searching

    target_class = new_target
    searching = True

    print("")
    print("================================")
    print(" Search started")
    print(" Target:", new_target)
    print("================================")


def stop_search():
    global target_class
    global searching

    target_class = None
    searching = False

    motor_stop_all()

    print("")
    print("================================")
    print(" Search stopped")
    print("================================")


# =========================================================
# Motor control
# =========================================================

def motor_strength_to_duty(percent):
    percent = max(0, min(100, percent))
    return int(65535 * (percent / 100.0))


def initialize_shared_i2c():
    global shared_i2c

    if shared_i2c is None:
        shared_i2c = busio.I2C(
            board.SCL,
            board.SDA
        )

    return shared_i2c


def initialize_motor():
    global pca
    global motor_i2c

    if not USE_MOTOR:
        print("[MOTOR] Disabled")
        return

    print("[MOTOR] Initializing PCA9685...")

    motor_i2c = initialize_shared_i2c()

    pca = PCA9685(
        motor_i2c
    )

    pca.frequency = PCA9685_FREQUENCY

    motor_stop_all()

    print("[MOTOR] PCA9685 ready")
    print(
        "[MOTOR] Channels: "
        "TOP=0 LEFT=1 BOTTOM=2 RIGHT=3"
    )
    print(
        f"[MOTOR] Strength: {MOTOR_STRENGTH_PERCENT}%"
    )


def motor_stop_all():
    global pca
    global last_motor_direction

    if pca is None:
        return

    for channel in [
        MOTOR_TOP,
        MOTOR_LEFT,
        MOTOR_BOTTOM,
        MOTOR_RIGHT
    ]:
        pca.channels[channel].duty_cycle = 0

    last_motor_direction = None


def motor_set_direction(direction):
    global last_motor_direction
    global last_motor_update_time

    if pca is None:
        return

    now = time.time()

    if (
        direction == last_motor_direction
        and now - last_motor_update_time < MOTOR_UPDATE_INTERVAL
    ):
        return

    motor_stop_all()

    channels = DIRECTION_TO_CHANNELS.get(
        direction,
        []
    )

    duty = motor_strength_to_duty(
        MOTOR_STRENGTH_PERCENT
    )

    for channel in channels:
        pca.channels[channel].duty_cycle = duty

    last_motor_direction = direction
    last_motor_update_time = now

    print(
        "[MOTOR]",
        direction,
        "->",
        channels
    )


def cleanup_motor():
    global pca
    global motor_i2c

    if pca is not None:
        try:
            motor_stop_all()
            pca.deinit()
        except Exception:
            pass

    pca = None
    motor_i2c = None



# =========================================================
# ToF control
# =========================================================

def cleanup_tof():
    global tof_xshut
    global tof_sensors

    for sensor in tof_sensors:
        try:
            sensor.stop_ranging()
        except Exception:
            pass

    for pin in tof_xshut:
        try:
            pin.value = False
        except Exception:
            pass

    for pin in tof_xshut:
        try:
            pin.deinit()
        except Exception:
            pass

    tof_sensors = []
    tof_xshut = []


def initialize_tof():
    global tof_i2c
    global tof_xshut
    global tof_sensors
    global tof_last_values
    global tof_error_counts
    global tof_recovery_requested

    if not USE_TOF:
        print("[ToF] Disabled")
        return

    cleanup_tof()

    print("")
    print("================================")
    print(" 8 ToF initialization")
    print("================================")

    tof_i2c = initialize_shared_i2c()
    tof_xshut = []

    # Shut down all 8 sensors first.
    for pin_name in TOF_XSHUT_PINS:
        pin = digitalio.DigitalInOut(
            pin_name
        )
        pin.direction = digitalio.Direction.OUTPUT
        pin.value = False
        tof_xshut.append(
            pin
        )

    time.sleep(1.0)

    tof_sensors = []
    tof_last_values = [None] * len(
        TOF_ADDRESSES
    )
    tof_error_counts = [0] * len(
        TOF_ADDRESSES
    )
    tof_recovery_requested = False

    # Enable one sensor at a time.
    # The newly enabled sensor appears at default address 0x29.
    for i, new_address in enumerate(
        TOF_ADDRESSES
    ):
        print(
            f"[ToF] Starting sensor {i + 1}..."
        )

        tof_xshut[i].value = True
        time.sleep(0.20)

        sensor = adafruit_vl53l1x.VL53L1X(
            tof_i2c
        )

        sensor.set_address(
            new_address
        )

        sensor.distance_mode = (
            TOF_DISTANCE_MODE
        )
        sensor.timing_budget = (
            TOF_TIMING_BUDGET_MS
        )
        sensor.start_ranging()

        tof_sensors.append(
            sensor
        )

        print(
            f"[ToF] Sensor {i + 1}: "
            f"0x29 -> 0x{new_address:02X}"
        )

        time.sleep(0.05)

    print("")
    print("[ToF] All 8 sensors ready")
    print(
        "[ToF] Addresses:",
        " ".join(
            f"0x{address:02X}"
            for address in TOF_ADDRESSES
        )
    )
    print("[ToF] Default 0x29 is unused")


def read_tof_once():
    global tof_last_values
    global tof_error_counts
    global tof_recovery_requested

    if not USE_TOF or not tof_sensors:
        return tof_last_values

    for i, sensor in enumerate(
        tof_sensors
    ):
        try:
            if sensor.data_ready:
                distance = sensor.distance
                sensor.clear_interrupt()

                tof_last_values[i] = (
                    None
                    if distance is None
                    else round(
                        float(distance),
                        1
                    )
                )

                # Successful I2C communication resets this sensor's counter.
                tof_error_counts[i] = 0

        except OSError as e:
            tof_last_values[i] = None
            tof_error_counts[i] += 1

            print(
                f"[ToF] Sensor {i + 1} I2C error "
                f"({tof_error_counts[i]}/"
                f"{TOF_MAX_CONSECUTIVE_ERRORS}):",
                e
            )

            if (
                tof_error_counts[i]
                >= TOF_MAX_CONSECUTIVE_ERRORS
            ):
                tof_recovery_requested = True

        except Exception as e:
            tof_last_values[i] = None
            tof_error_counts[i] += 1

            print(
                f"[ToF] Sensor {i + 1} read error "
                f"({tof_error_counts[i]}/"
                f"{TOF_MAX_CONSECUTIVE_ERRORS}):",
                e
            )

            if (
                tof_error_counts[i]
                >= TOF_MAX_CONSECUTIVE_ERRORS
            ):
                tof_recovery_requested = True

    return tof_last_values


def recover_tof_if_needed():
    global tof_recovery_requested
    global tof_recovering
    global tof_last_recovery_time

    if not USE_TOF:
        return False

    if not tof_recovery_requested:
        return False

    if tof_recovering:
        return False

    now = time.time()

    if (
        now - tof_last_recovery_time
        < TOF_RECOVERY_COOLDOWN_SEC
    ):
        return False

    tof_recovering = True

    print("")
    print("================================")
    print(" ToF automatic recovery")
    print("================================")
    print(
        "[ToF] Repeated I2C errors detected."
    )
    print(
        "[ToF] Stopping motors and rebuilding "
        "all 8 ToF addresses..."
    )

    motor_stop_all()

    try:
        time.sleep(
            TOF_RECOVERY_SETTLE_SEC
        )

        initialize_tof()

        tof_last_recovery_time = (
            time.time()
        )

        print(
            "[ToF] Automatic recovery complete"
        )
        print("================================")
        print("")

        if (
            smartcane_characteristic is not None
            and smartcane_characteristic.notifying
        ):
            smartcane_characteristic.send_json(
                {
                    "type": "tof_recovery",
                    "state": "recovered"
                }
            )

        return True

    except Exception as e:
        tof_last_recovery_time = (
            time.time()
        )

        # Keep retry request active for the next cooldown window.
        tof_recovery_requested = True

        print(
            "[ToF] Automatic recovery failed:",
            e
        )

        if (
            smartcane_characteristic is not None
            and smartcane_characteristic.notifying
        ):
            smartcane_characteristic.send_json(
                {
                    "type": "tof_recovery",
                    "state": "failed",
                    "message": str(e)
                }
            )

        return False

    finally:
        tof_recovering = False


def print_tof_values():
    values = []

    for i, distance in enumerate(
        tof_last_values
    ):
        if distance is None:
            values.append(
                f"ToF{i + 1}: ---"
            )
        else:
            values.append(
                f"ToF{i + 1}: {distance:.1f} cm"
            )

    print(
        "[ToF]",
        " | ".join(values)
    )


def send_tof_values():
    if (
        smartcane_characteristic is None
        or not smartcane_characteristic.notifying
    ):
        return

    smartcane_characteristic.send_json(
        {
            "type": "tof",
            "unit": "cm",
            "values": tof_last_values,
        }
    )


# =========================================================
# X120x status functions
# =========================================================

def initialize_x120x():
    global x120x_bus
    global pld_button

    if not USE_X120X:
        print("[X120x] Disabled")
        return

    x120x_bus = smbus2.SMBus(1)
    pld_button = Button(PLD_PIN)

    print("[X120x] Status reader ready")


def read_voltage_and_capacity():
    if x120x_bus is None:
        return None, None

    voltage_read = x120x_bus.read_word_data(
        X120X_ADDRESS,
        2
    )

    capacity_read = x120x_bus.read_word_data(
        X120X_ADDRESS,
        4
    )

    voltage_swapped = struct.unpack(
        "<H",
        struct.pack(
            ">H",
            voltage_read
        )
    )[0]

    voltage = (
        voltage_swapped
        * 1.25
        / 1000
        / 16
    )

    capacity_swapped = struct.unpack(
        "<H",
        struct.pack(
            ">H",
            capacity_read
        )
    )[0]

    capacity = (
        capacity_swapped
        / 256
    )

    return voltage, capacity


def get_pld_state():
    if pld_button is None:
        return None

    return (
        0
        if pld_button.is_pressed
        else 1
    )


def read_hardware_metric(
    command_args,
    strip_chars
):
    try:
        output = check_output(
            command_args
        ).decode(
            "utf-8"
        )

        metric_str = (
            output
            .split("=")[1]
            .strip()
            .rstrip(strip_chars)
        )

        return float(
            metric_str
        )

    except (
        CalledProcessError,
        ValueError,
        IndexError,
        FileNotFoundError
    ):
        return None


def read_cpu_volts():
    return read_hardware_metric(
        [
            "vcgencmd",
            "pmic_read_adc",
            "VDD_CORE_V"
        ],
        "V"
    )


def read_cpu_amps():
    return read_hardware_metric(
        [
            "vcgencmd",
            "pmic_read_adc",
            "VDD_CORE_A"
        ],
        "A"
    )


def read_cpu_temp():
    return read_hardware_metric(
        [
            "vcgencmd",
            "measure_temp"
        ],
        "'C"
    )


def read_input_voltage():
    return read_hardware_metric(
        [
            "vcgencmd",
            "pmic_read_adc",
            "EXT5V_V"
        ],
        "V"
    )


def get_fan_rpm():
    try:
        sys_devices_path = Path(
            "/sys/devices/platform/cooling_fan"
        )

        fan_input_files = list(
            sys_devices_path.rglob(
                "fan1_input"
            )
        )

        if not fan_input_files:
            return None

        with open(
            fan_input_files[0],
            "r"
        ) as file:
            return int(
                file.read().strip()
            )

    except Exception:
        return None


def power_consumption_watts():
    try:
        output = check_output(
            [
                "vcgencmd",
                "pmic_read_adc"
            ]
        ).decode(
            "utf-8"
        )

        amperages = {}
        voltages = {}

        for line in output.splitlines():
            cleaned_line = line.strip()

            if not cleaned_line:
                continue

            parts = cleaned_line.split()

            if len(parts) < 2:
                continue

            label = parts[0]
            value = parts[-1]

            try:
                val = float(
                    value
                    .split("=")[1][:-1]
                )
            except (
                ValueError,
                IndexError
            ):
                continue

            short_label = label[:-2]

            if label.endswith("A"):
                amperages[short_label] = val
            else:
                voltages[short_label] = val

        return sum(
            amperages[key]
            * voltages[key]
            for key in amperages
            if key in voltages
        )

    except Exception:
        return None


def get_status_data():
    voltage, capacity = (
        read_voltage_and_capacity()
    )

    cpu_volts = read_cpu_volts()
    cpu_amps = read_cpu_amps()
    cpu_temp = read_cpu_temp()
    input_voltage = read_input_voltage()
    fan_rpm = get_fan_rpm()
    pwr_use = power_consumption_watts()
    pld_state = get_pld_state()

    # Charging state for the Flutter UI.
    #
    # pld_state == 1 means external AC power is present.
    # The X120x status code does not directly measure battery charge current,
    # so "charging" below means:
    #   external power is connected + battery is below the charge cutoff.
    #
    # This gives the UI practical states:
    # charging / not_charging / disabled / unknown.
    if capacity is None or pld_state is None:
        charge_status = "unknown"
    elif capacity >= 90:
        charge_status = "disabled"
    elif pld_state == 1:
        charge_status = "charging"
    else:
        charge_status = "not_charging"

    if pld_state is None:
        power_status = "UNKNOWN"
    elif pld_state == 1:
        power_status = "AC_OK"
    else:
        power_status = "UPS_BACKUP"

    warning = ""

    if (
        pld_state == 0
        and capacity is not None
    ):
        if capacity <= 15:
            warning = "CRITICAL_SHUTDOWN_LEVEL"
        elif capacity <= 24:
            warning = "CRITICAL"
        elif capacity <= 50:
            warning = "LOW"
        else:
            warning = "UPS_BACKUP"

    return {
        "type": "status",

        # Main UI values
        "battery": safe_round(
            capacity,
            1
        ),
        "charging": charge_status,

        # Detail UI values
        "battery_voltage": safe_round(
            voltage,
            3
        ),
        "input_voltage": safe_round(
            input_voltage,
            3
        ),
        "cpu_voltage": safe_round(
            cpu_volts,
            3
        ),
        "cpu_current": safe_round(
            cpu_amps,
            3
        ),
        "cpu_temp": safe_round(
            cpu_temp,
            1
        ),
        "power_watts": safe_round(
            pwr_use,
            3
        ),
        "fan_rpm": fan_rpm,
        "power_status": power_status,
        "warning": warning,
    }


# =========================================================
# BLE command handler
# =========================================================

def handle_command(text):
    text = text.strip()

    print("")
    print("================================")
    print("[WEB -> PI]")
    print(text)
    print("================================")

    if text.upper() == "PING":
        if smartcane_characteristic is not None:
            smartcane_characteristic.send_to_web(
                "PONG FROM PI"
            )
        return

    if text.upper() == "STATUS":
        if smartcane_characteristic is not None:
            try:
                smartcane_characteristic.send_json(
                    get_status_data()
                )
            except Exception as e:
                smartcane_characteristic.send_json(
                    {
                        "type": "error",
                        "message": str(e)
                    }
                )
        return

    if text.upper() == "STOP":
        stop_search()

        if smartcane_characteristic is not None:
            smartcane_characteristic.send_json(
                {
                    "type": "search",
                    "state": "stopped"
                }
            )
        return

    if text.startswith("FIND:"):
        target = text.split(
            ":",
            1
        )[1].strip()

        if target:
            set_target(target)

            if smartcane_characteristic is not None:
                smartcane_characteristic.send_json(
                    {
                        "type": "search",
                        "state": "started",
                        "target": target
                    }
                )
        else:
            print("Invalid FIND command")

        return

    print("Unknown command")


# =========================================================
# BLE GATT Application
# =========================================================

class Application(
    dbus.service.Object
):

    def __init__(
        self,
        bus
    ):
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

    def add_service(
        self,
        service
    ):
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


class Service(
    dbus.service.Object
):

    PATH_BASE = (
        "/org/bluez/example/service"
    )

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


class Characteristic(
    dbus.service.Object
):

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

        handle_command(
            text
        )

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

    @dbus.service.method(
        GATT_CHRC_IFACE
    )
    def StartNotify(
        self
    ):
        if self.notifying:
            return

        self.notifying = True

        print("")
        print(
            "[BLE] Notify enabled by Web/App"
        )

        self.send_to_web(
            "HELLO FROM PI"
        )

    @dbus.service.method(
        GATT_CHRC_IFACE
    )
    def StopNotify(
        self
    ):
        self.notifying = False

        print("")
        print(
            "[BLE] Notify disabled by Web/App"
        )

    def send_to_web(
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
        print("[PI -> WEB]")
        print(message)
        print("================================")

        if not self.notifying:
            print(
                "[BLE] Notify is not enabled yet"
            )
            return

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

        self.send_to_web(
            message
        )


class SmartCaneService(
    Service
):

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
# Camera preprocessing
# =========================================================

def letterbox(
    image,
    new_size=(640, 640),
    color=(114, 114, 114)
):
    original_h, original_w = (
        image.shape[:2]
    )

    target_w, target_h = new_size

    scale = min(
        target_w / original_w,
        target_h / original_h
    )

    resized_w = int(
        round(
            original_w * scale
        )
    )

    resized_h = int(
        round(
            original_h * scale
        )
    )

    resized = cv2.resize(
        image,
        (
            resized_w,
            resized_h
        ),
        interpolation=cv2.INTER_LINEAR
    )

    pad_w = (
        target_w
        - resized_w
    )

    pad_h = (
        target_h
        - resized_h
    )

    pad_left = (
        pad_w // 2
    )

    pad_right = (
        pad_w
        - pad_left
    )

    pad_top = (
        pad_h // 2
    )

    pad_bottom = (
        pad_h
        - pad_top
    )

    return cv2.copyMakeBorder(
        resized,
        pad_top,
        pad_bottom,
        pad_left,
        pad_right,
        cv2.BORDER_CONSTANT,
        value=color
    )


# =========================================================
# Direction calculation
# =========================================================

def bbox_to_direction(
    bbox,
    width=640,
    height=640
):
    x1, y1, x2, y2 = bbox

    center_x = (
        x1 + x2
    ) / 2

    center_y = (
        y1 + y2
    ) / 2

    cell_w = (
        width / 3
    )

    cell_h = (
        height / 3
    )

    if center_x < cell_w:
        horizontal = "LEFT"
    elif center_x < cell_w * 2:
        horizontal = "CENTER"
    else:
        horizontal = "RIGHT"

    if center_y < cell_h:
        vertical = "TOP"
    elif center_y < cell_h * 2:
        vertical = "CENTER"
    else:
        vertical = "BOTTOM"

    if (
        vertical == "CENTER"
        and horizontal == "CENTER"
    ):
        return "CENTER"

    if vertical == "CENTER":
        return horizontal

    if horizontal == "CENTER":
        return vertical

    return (
        vertical
        + "+"
        + horizontal
    )


# =========================================================
# Drawing
# =========================================================

def draw_grid(image):
    h, w = image.shape[:2]

    x1 = w // 3
    x2 = (w * 2) // 3

    y1 = h // 3
    y2 = (h * 2) // 3

    cv2.line(
        image,
        (x1, 0),
        (x1, h),
        (255, 255, 255),
        2
    )

    cv2.line(
        image,
        (x2, 0),
        (x2, h),
        (255, 255, 255),
        2
    )

    cv2.line(
        image,
        (0, y1),
        (w, y1),
        (255, 255, 255),
        2
    )

    cv2.line(
        image,
        (0, y2),
        (w, y2),
        (255, 255, 255),
        2
    )


def draw_detection(
    image,
    bbox,
    class_name,
    confidence,
    direction
):
    x1, y1, x2, y2 = [
        int(value)
        for value in bbox
    ]

    cv2.rectangle(
        image,
        (x1, y1),
        (x2, y2),
        (0, 0, 255),
        3
    )

    center_x = int(
        (x1 + x2) / 2
    )

    center_y = int(
        (y1 + y2) / 2
    )

    cv2.circle(
        image,
        (
            center_x,
            center_y
        ),
        7,
        (0, 255, 255),
        -1
    )

    label = (
        f"{class_name} "
        f"{confidence:.2f} "
        f"{direction}"
    )

    cv2.putText(
        image,
        label,
        (
            x1,
            max(
                30,
                y1 - 10
            )
        ),
        cv2.FONT_HERSHEY_SIMPLEX,
        0.75,
        (0, 0, 255),
        2
    )


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
        print("Waiting for Web/App connection...")
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
# Main
# =========================================================

def main():
    global last_motor_update_time

    print("")
    print("================================")
    print(" SmartCane Full Integration Test")
    print(" BLE + X120x + 8 ToF + Camera + YOLO + Motor")
    print("================================")
    print("")
    print("Camera :", "ON" if USE_CAMERA else "OFF")
    print("YOLO   :", "ON" if USE_YOLO else "OFF")
    print("Motor  :", "ON" if USE_MOTOR else "OFF")
    print("X120x  :", "ON" if USE_X120X else "OFF")
    print("ToF    :", "ON" if USE_TOF else "OFF")
    print("")

    setup_bluetooth_controller()

    bus, app, glib_context = (
        initialize_ble()
    )

    _ = bus
    _ = app

    initialize_x120x()
    initialize_tof()
    initialize_motor()

    model = None
    picam2 = None

    if USE_YOLO:
        print("Loading YOLO model...")

        model = YOLO(
            YOLO_MODEL_PATH
        )

        print("YOLO model loaded")

    if USE_CAMERA:
        print("Starting camera...")

        picam2 = Picamera2()

        camera_config = (
            picam2.create_preview_configuration(
                main={
                    "size": (
                        640,
                        480
                    ),
                    "format": "RGB888"
                }
            )
        )

        picam2.configure(
            camera_config
        )

        picam2.start()

        time.sleep(1)

        print("Camera ready")

    last_print_time = 0.0
    last_status_time = 0.0
    last_tof_read_time = 0.0
    last_tof_print_time = 0.0
    last_tof_ble_time = 0.0
    last_found_direction = None

    try:
        while True:
            while glib_context.pending():
                glib_context.iteration(
                    False
                )

            now = time.time()

            # ---------------------------------
            # Send Raspberry Pi / X120x status
            # ---------------------------------

            if (
                USE_X120X
                and smartcane_characteristic is not None
                and smartcane_characteristic.notifying
                and now - last_status_time >= STATUS_INTERVAL_SEC
            ):
                try:
                    smartcane_characteristic.send_json(
                        get_status_data()
                    )
                except Exception as e:
                    print(
                        "[STATUS] Failed:",
                        e
                    )

                last_status_time = now

            # ---------------------------------
            # 8 x ToF read / recovery / output
            # ---------------------------------

            if (
                USE_TOF
                and now - last_tof_read_time
                >= TOF_READ_INTERVAL_SEC
            ):
                read_tof_once()
                last_tof_read_time = now

            if USE_TOF:
                recovered = recover_tof_if_needed()

                if recovered:
                    now = time.time()
                    last_tof_read_time = now
                    last_tof_print_time = now
                    last_tof_ble_time = now

            if (
                USE_TOF
                and now - last_tof_print_time
                >= TOF_PRINT_INTERVAL_SEC
            ):
                print_tof_values()
                last_tof_print_time = now

            if (
                USE_TOF
                and now - last_tof_ble_time
                >= TOF_BLE_INTERVAL_SEC
            ):
                send_tof_values()
                last_tof_ble_time = now

            # ---------------------------------
            # Camera / YOLO
            # ---------------------------------

            if not USE_CAMERA:
                time.sleep(0.05)
                continue

            frame = picam2.capture_array()

            boxed = letterbox(
                frame,
                new_size=(
                    WIDTH,
                    HEIGHT
                )
            )

            draw_grid(
                boxed
            )

            if (
                not searching
                or target_class is None
            ):
                motor_stop_all()

                cv2.putText(
                    boxed,
                    "Waiting for app command",
                    (20, 40),
                    cv2.FONT_HERSHEY_SIMPLEX,
                    0.9,
                    (0, 255, 255),
                    2
                )

            elif USE_YOLO and model is not None:
                current_target = target_class

                results = model(
                    boxed,
                    imgsz=640,
                    conf=CONFIDENCE_THRESHOLD,
                    verbose=False
                )

                best_detection = None

                for result in results:
                    for box in result.boxes:
                        cls_id = int(
                            box.cls[0]
                        )

                        class_name = (
                            model.names[
                                cls_id
                            ]
                        )

                        confidence = float(
                            box.conf[0]
                        )

                        if (
                            class_name
                            != current_target
                        ):
                            continue

                        x1, y1, x2, y2 = (
                            box.xyxy[
                                0
                            ].tolist()
                        )

                        bbox = (
                            x1,
                            y1,
                            x2,
                            y2
                        )

                        if (
                            best_detection is None
                            or confidence
                            > best_detection[
                                "confidence"
                            ]
                        ):
                            best_detection = {
                                "bbox": bbox,
                                "class_name": class_name,
                                "confidence": confidence
                            }

                if best_detection is not None:
                    bbox = (
                        best_detection[
                            "bbox"
                        ]
                    )

                    class_name = (
                        best_detection[
                            "class_name"
                        ]
                    )

                    confidence = (
                        best_detection[
                            "confidence"
                        ]
                    )

                    direction = (
                        bbox_to_direction(
                            bbox,
                            WIDTH,
                            HEIGHT
                        )
                    )

                    draw_detection(
                        boxed,
                        bbox,
                        class_name,
                        confidence,
                        direction
                    )

                    motor_set_direction(
                        direction
                    )

                    if (
                        direction
                        != last_found_direction
                        and smartcane_characteristic is not None
                        and smartcane_characteristic.notifying
                    ):
                        smartcane_characteristic.send_json(
                            {
                                "type": "object",
                                "target": class_name,
                                "confidence": round(
                                    confidence,
                                    2
                                ),
                                "direction": direction
                            }
                        )

                        last_found_direction = (
                            direction
                        )

                    if (
                        now - last_print_time
                        >= 0.5
                    ):
                        print(
                            "FOUND:",
                            class_name,
                            "confidence:",
                            round(
                                confidence,
                                2
                            ),
                            "direction:",
                            direction
                        )

                        last_print_time = now

                else:
                    motor_stop_all()
                    last_found_direction = None

                    cv2.putText(
                        boxed,
                        "Searching: "
                        + current_target,
                        (20, 40),
                        cv2.FONT_HERSHEY_SIMPLEX,
                        0.9,
                        (0, 0, 255),
                        2
                    )

            if SHOW_CAMERA_WINDOW:
                cv2.imshow(
                    "SmartCane Full Integration Test",
                    boxed
                )

                key = (
                    cv2.waitKey(1)
                    & 0xFF
                )

                if key == ord("q"):
                    break

    except KeyboardInterrupt:
        print("")
        print(
            "Program stopped by user"
        )

    finally:
        cleanup_tof()
        motor_stop_all()
        cleanup_motor()

        if picam2 is not None:
            try:
                picam2.stop()
            except Exception:
                pass

        if SHOW_CAMERA_WINDOW:
            cv2.destroyAllWindows()

        if x120x_bus is not None:
            try:
                x120x_bus.close()
            except Exception:
                pass

        print("Cleanup complete")


if __name__ == "__main__":
    main()
