#!/usr/bin/env python3

import os
import sys
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
from libcamera import Transform, controls
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

# Show the OpenCV preview window only when a desktop display is available.
# When started by systemd at boot there is no DISPLAY, so this turns off
# automatically and cv2.imshow() is never called.
SHOW_CAMERA_WINDOW = bool(os.environ.get("DISPLAY"))


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

# Picamera2 main stream (letterboxed to WIDTH x HEIGHT for YOLO).
CAMERA_SIZE = (640, 480)
CAMERA_FORMAT = "RGB888"
# Camera is mounted upside down -> rotate 180 degrees.
CAMERA_HFLIP = True
CAMERA_VFLIP = True

# ---- Image quality for YOLO (verified with camera_test.py, 2026-10-14) ----
# Sensor mode. Without this Picamera2 picks the smallest 1536x864 (3x3 binned)
# mode for a 640x480 output; the 2304x1296 (2x2 binned) mode scaled down by
# the ISP keeps more detail. YOLO runs at ~3-4 fps, so the lower sensor fps
# (56 instead of 120) does not matter.
CAMERA_SENSOR_SIZE = (2304, 1296)
# Camera Module 3 (standard lens) has a shallower depth of field than the
# wide version, so keep continuous autofocus on. Fast speed because the cane
# moves; Normal range avoids hunting into macro distances.
CAMERA_AUTOFOCUS = True
# Centre-weighted metering: expose for the object in the middle of the frame
# rather than a bright window/sky behind it.
CAMERA_METERING_CENTRE = True
# Pi 5 ISP HDR (backlight compensation). Works on this Pi; off by default.
CAMERA_HDR = False
# queue=False -> capture_array() always returns the newest frame, so a slow
# YOLO loop does not act on a stale one.
CAMERA_QUEUE = False

YOLO_MODEL_PATH = "yolov8n.pt"
CONFIDENCE_THRESHOLD = 0.35
YOLO_CLASSES_PER_BLE_CHUNK = 6


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

# Navigation vibrations are short cues, not continuous motor output.
# TOP/front=straight, LEFT=left turn, RIGHT=right turn, BOTTOM/back=U-turn.
NAVIGATION_MOTOR_DURATION_SEC = {
    "FORWARD": 0.25,
    "LEFT": 0.60,
    "RIGHT": 0.60,
    "UTURN": 0.85,
}

NAVIGATION_TO_MOTOR_DIRECTION = {
    "FORWARD": "TOP",
    "LEFT": "LEFT",
    "RIGHT": "RIGHT",
    "UTURN": "BOTTOM",
}

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
# ToF settings - 6 x VL53L1X
# =========================================================

TOF_ADDRESSES = [
    0x2A,
    0x2B,
    0x2C,
    0x2E,
    0x2F,
    0x30,
]

TOF_XSHUT_PINS = [
    board.D17,
    board.D27,
    board.D22,
    board.D24,
    board.D25,
    board.D5,
]

TOF_DISTANCE_MODE = 2
TOF_TIMING_BUDGET_MS = 100

TOF_READ_INTERVAL_SEC = 0.10
TOF_PRINT_INTERVAL_SEC = 0.50
TOF_BLE_INTERVAL_SEC = 0.50

# Physical order must match TOF_XSHUT_PINS and TOF_ADDRESSES above.
# Logical hazard grouping:
# ToF1      = LEFT
# ToF2~3    = FRONT
# ToF4      = RIGHT
# ToF5~6    = UPPER
#
# ToF1 = LEFT  (GPIO17, 0x2A)
# ToF2 = FRONT (GPIO27, 0x2B)
# ToF3 = FRONT (GPIO22, 0x2C)
# ToF4 = RIGHT (GPIO24, 0x2E)
# ToF5 = UPPER (GPIO25, 0x2F)
# ToF6 = UPPER (GPIO5,  0x30)
TOF_SENSOR_LAYOUT = [
    # ToF1: 왼쪽
    {"position": "LEFT", "label": "왼쪽", "threshold_cm": 75.0},

    # ToF2~3: 정면
    {"position": "FRONT", "label": "정면", "threshold_cm": 150.0},
    {"position": "FRONT", "label": "정면", "threshold_cm": 150.0},

    # ToF4: 오른쪽
    {"position": "RIGHT", "label": "오른쪽", "threshold_cm": 75.0},

    # ToF5~6: 위쪽
    {"position": "UPPER", "label": "위쪽", "threshold_cm": 200.0},
    {"position": "UPPER", "label": "위쪽", "threshold_cm": 200.0},
]

# 내부 로직은 LEFT/FRONT/RIGHT/UPPER를 그대로 사용하고,
# 앱으로 전송하거나 로그에 표시할 때만 한글로 변환한다.
TOF_POSITION_KO = {
    "LEFT": "왼쪽",
    "FRONT": "정면",
    "RIGHT": "오른쪽",
    "UPPER": "위쪽",
}

# 앱에서 위험 감지 거리를 줄일 때 쓰는 방향 묶음.
# LEFT/RIGHT는 "양쪽(SIDE)" 하나의 값으로 같이 조절한다.
HAZARD_DISTANCE_GROUPS = ("FRONT", "SIDE", "UPPER")
HAZARD_GROUP_BY_POSITION = {
    "LEFT": "SIDE",
    "FRONT": "FRONT",
    "RIGHT": "SIDE",
    "UPPER": "UPPER",
}
HAZARD_DISTANCE_LABEL_KO = {
    "FRONT": "정면",
    "SIDE": "양쪽",
    "UPPER": "위쪽",
}

# 묶음별 기본 위험 거리 = 그 묶음 센서 threshold_cm 중 가장 큰 값
# (현재 정면 150cm, 양쪽 75cm, 위쪽 200cm). 앱은 이 값보다 줄이는 것만 할 수 있다.
HAZARD_DEFAULT_DISTANCE_CM = {
    group: max(
        int(sensor_info["threshold_cm"])
        for sensor_info in TOF_SENSOR_LAYOUT
        if HAZARD_GROUP_BY_POSITION[sensor_info["position"]] == group
    )
    for group in HAZARD_DISTANCE_GROUPS
}

# 10cm 미만은 센서 오차 범위라 의미가 없다.
HAZARD_MIN_DISTANCE_CM = 10

TOF_HAZARD_BLE_REPEAT_SEC = 5.0
TOF_HAZARD_CLEAR_READS = 3

# Hazard vibration pattern
# Each sensor's danger range is divided into 3 proportional zones:
# nearest 1/3  -> 3 short pulses
# middle 1/3   -> 2 short pulses
# farthest 1/3 -> 1 short pulse
#
# Current ranges:
# LEFT/RIGHT 75cm: 0~25cm 3 pulses, 26~50cm 2 pulses, 51~75cm 1 pulse
# FRONT 150cm: 0~50cm 3 pulses, 51~100cm 2 pulses, 101~150cm 1 pulse
# UPPER 200cm: 0~66cm 3 pulses, 67~133cm 2 pulses, 134~200cm 1 pulse
# 앱에서 방향별 거리를 줄이면 줄인 거리를 기준으로 같은 1/3 비율을 쓴다.
TOF_HAZARD_PULSE_ON_SEC = 0.22
TOF_HAZARD_PULSE_GAP_SEC = 0.18
TOF_HAZARD_CYCLE_GAP_SEC = {
    1: 2.50,
    2: 1.80,
    3: 1.20,
}

# Recovery settings
TOF_MAX_CONSECUTIVE_ERRORS = 5
TOF_RECOVERY_COOLDOWN_SEC = 2.0
TOF_RECOVERY_SETTLE_SEC = 1.0

tof_i2c = None
tof_xshut = []
tof_sensors = []
tof_last_values = [None] * len(TOF_ADDRESSES)
tof_error_counts = [0] * len(TOF_ADDRESSES)
tof_recovery_requested = False
tof_recovering = False
tof_last_recovery_time = 0.0
tof_hazard_active = False
tof_hazard_detections = []
tof_hazard_clear_count = 0
tof_last_hazard_signature = None
tof_last_hazard_ble_time = 0.0
tof_hazard_pulse_count = 0
tof_hazard_pulses_done = 0
tof_hazard_motor_on = False
tof_hazard_next_transition_time = 0.0

# 앱(설정 탭)에서 BLE로 바꾸는 위험 감지 옵션
# HAZARD:ON / HAZARD:OFF                    -> hazard_enabled
# HAZARD:DIST:<FRONT|SIDE|UPPER>:<cm|DEFAULT> -> 그 방향의 hazard_distance_limits_cm
# HAZARD:DIST:<cm|DEFAULT>                  -> 세 방향 모두 (구버전 앱 호환)
# 값이 None이면 그 방향은 센서별 기본 threshold를 그대로 쓴다.
hazard_enabled = True
hazard_distance_limits_cm = {
    group: None
    for group in HAZARD_DISTANCE_GROUPS
}


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
yolo_class_names = []

smartcane_characteristic = None

pca = None
motor_i2c = None
shared_i2c = None
last_motor_direction = None
last_motor_update_time = 0.0
navigation_motor_direction = None
navigation_motor_until = 0.0
object_motor_active = False


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
    global object_motor_active

    target_class = None
    searching = False
    object_motor_active = False

    if tof_hazard_active:
        motor_set_direction("CENTER")
    else:
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


def start_navigation_motor_cue(action):
    global navigation_motor_direction
    global navigation_motor_until

    action = action.strip().upper()

    if action == "STOP":
        navigation_motor_direction = None
        navigation_motor_until = 0.0
        if tof_hazard_active:
            motor_set_direction("CENTER")
        else:
            motor_stop_all()
        print("[NAV MOTOR] STOP")
        return True

    motor_direction = NAVIGATION_TO_MOTOR_DIRECTION.get(
        action
    )
    duration = NAVIGATION_MOTOR_DURATION_SEC.get(
        action
    )

    if motor_direction is None or duration is None:
        return False

    if pca is None:
        print(
            "[NAV MOTOR] PCA9685 is not initialized"
        )
        return False

    navigation_motor_direction = motor_direction
    navigation_motor_until = time.time() + duration
    # 媛앹껜 ?먯깋 吏꾨룞???대? 異쒕젰 以묒씠硫?洹?異쒕젰???딆? ?딄퀬, ?먯???媛앹껜媛
    # ?щ씪吏??利됱떆 ?⑥? ?대퉬寃뚯씠???덈궡 ?쒓컙 ?숈븞 吏꾨룞???댁뼱??異쒕젰?쒕떎.
    if not object_motor_active and not tof_hazard_active:
        motor_set_direction(motor_direction)

    print(
        "[NAV MOTOR]",
        action,
        "->",
        motor_direction,
        f"({duration:.2f}s)"
    )
    return True


def update_navigation_motor_cue(now):
    global navigation_motor_direction
    global navigation_motor_until

    if navigation_motor_direction is None:
        return False

    if now >= navigation_motor_until:
        navigation_motor_direction = None
        navigation_motor_until = 0.0
        if not object_motor_active and not tof_hazard_active:
            motor_stop_all()
        return False

    if (
        not object_motor_active
        and not tof_hazard_active
        and last_motor_direction != navigation_motor_direction
    ):
        motor_set_direction(
            navigation_motor_direction
        )

    return True


def apply_navigation_motor_if_active(now):
    """媛앹껜 吏꾨룞???놁쓣 ???⑥븘 ?덈뒗 ?대퉬寃뚯씠??吏꾨룞??異쒕젰?쒕떎."""
    # ?꾪뿕 媛먯? 以묒뿉??ToF ?꾪뿕 ?⑦꽩 ?쒖뼱 ?⑥닔媛 紐⑦꽣瑜??⑤룆 ?쒖뼱?쒕떎.
    # ?ш린??CENTER瑜??ㅼ떆 耳쒕㈃ ?꾪뿕 ?⑦꽩??OFF/?댁떇 援ш컙??臾댁떆?섏뼱
    # 紐⑦꽣媛 怨꾩냽 吏꾨룞?섎뒗 寃껋쿂???숈옉?섎?濡??꾨Т寃껊룄 嫄대뱶由ъ? ?딅뒗??
    if tof_hazard_active:
        return True

    active = update_navigation_motor_cue(now)

    if active and navigation_motor_direction is not None:
        motor_set_direction(navigation_motor_direction)
        return True

    motor_stop_all()
    return False


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
    print(" 6 ToF initialization")
    print("================================")

    tof_i2c = initialize_shared_i2c()
    tof_xshut = []

    # Shut down all 6 sensors first.
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
    print("[ToF] All 6 sensors ready")
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
                    else int(float(distance))
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
        "all 6 ToF addresses..."
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
                f"ToF{i + 1}: {int(distance)} cm"
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


def get_tof_hazard_detections():
    """Return every sensor currently at or inside its danger threshold."""
    detections = []

    for index, (sensor_info, distance) in enumerate(
        zip(TOF_SENSOR_LAYOUT, tof_last_values)
    ):
        if distance is None or distance <= 0:
            continue

        threshold = float(sensor_info["threshold_cm"])
        # 앱에서 이 방향의 거리를 줄였으면 센서 기본값보다 가까운 쪽을 쓴다.
        limit = hazard_distance_limits_cm.get(
            HAZARD_GROUP_BY_POSITION.get(sensor_info["position"])
        )
        if limit is not None:
            threshold = min(threshold, float(limit))
        if distance <= threshold:
            detections.append(
                {
                    "sensor": index + 1,
                    "position": sensor_info["position"],
                    "distance_cm": int(float(distance)),
                    "threshold_cm": threshold,
                }
            )

    return detections


def group_tof_hazard_detections(detections):
    """
    Merge multiple sensors that represent the same logical direction.

    FRONT: ToF2~3
    UPPER: ToF5~6

    If one or more sensors in the same direction detect a hazard,
    that direction is returned only once. The nearest distance in
    that direction is used.
    """
    grouped = {}

    for item in detections:
        position = item["position"]

        if (
            position not in grouped
            or item["distance_cm"] < grouped[position]["distance_cm"]
        ):
            grouped[position] = item

    direction_order = [
        "LEFT",
        "FRONT",
        "RIGHT",
        "UPPER",
    ]

    return [
        grouped[position]
        for position in direction_order
        if position in grouped
    ]


def send_tof_hazard(state, detections):
    if (
        smartcane_characteristic is None
        or not smartcane_characteristic.notifying
    ):
        return

    grouped_detections = group_tof_hazard_detections(
        detections
    )

    smartcane_characteristic.send_json(
        {
            "type": "hazard",
            "state": state,
            # Each logical direction appears only once.
            # If several sensors in one direction detect an obstacle,
            # the nearest distance for that direction is sent.
            "positions": [
                TOF_POSITION_KO.get(
                    item["position"],
                    item["position"]
                )
                for item in grouped_detections
            ],
            "distances_cm": [
                item["distance_cm"]
                for item in grouped_detections
            ],
        }
    )


def get_tof_hazard_pulse_count(detections):
    """Convert obstacle distance into 1/2/3 pulses using each sensor's threshold proportion."""
    if not detections:
        return 0

    # Different sensor groups have different danger thresholds.
    # Compare distance as a ratio of each sensor's own threshold so that
    # the vibration severity scales proportionally with the configured range.
    #
    # ratio <= 1/3 : 3 pulses
    # ratio <= 2/3 : 2 pulses
    # ratio <= 1.0 : 1 pulse
    most_dangerous_ratio = min(
        float(item["distance_cm"]) / float(item["threshold_cm"])
        for item in detections
        if float(item["threshold_cm"]) > 0.0
    )

    if most_dangerous_ratio <= (1.0 / 3.0):
        return 3

    if most_dangerous_ratio <= (2.0 / 3.0):
        return 2

    return 1


def reset_tof_hazard_pattern():
    global tof_hazard_pulse_count
    global tof_hazard_pulses_done
    global tof_hazard_motor_on
    global tof_hazard_next_transition_time

    tof_hazard_pulse_count = 0
    tof_hazard_pulses_done = 0
    tof_hazard_motor_on = False
    tof_hazard_next_transition_time = 0.0


def start_tof_hazard_pattern(now, pulse_count):
    global tof_hazard_pulse_count
    global tof_hazard_pulses_done
    global tof_hazard_motor_on
    global tof_hazard_next_transition_time

    tof_hazard_pulse_count = pulse_count
    tof_hazard_pulses_done = 0
    tof_hazard_motor_on = True
    tof_hazard_next_transition_time = (
        now + TOF_HAZARD_PULSE_ON_SEC
    )

    motor_set_direction("CENTER")


def update_tof_hazard_motor_pattern(now, pulse_count):
    """Run 1/2/3-pulse all-motor warning pattern without blocking the main loop."""
    global tof_hazard_pulse_count
    global tof_hazard_pulses_done
    global tof_hazard_motor_on
    global tof_hazard_next_transition_time

    if pulse_count <= 0:
        reset_tof_hazard_pattern()
        return

    if (
        tof_hazard_pulse_count != pulse_count
        or tof_hazard_next_transition_time <= 0.0
    ):
        start_tof_hazard_pattern(
            now,
            pulse_count
        )
        return

    if now < tof_hazard_next_transition_time:
        return

    if tof_hazard_motor_on:
        motor_stop_all()
        tof_hazard_motor_on = False
        tof_hazard_pulses_done += 1

        if tof_hazard_pulses_done >= tof_hazard_pulse_count:
            tof_hazard_pulses_done = 0
            tof_hazard_next_transition_time = (
                now
                + TOF_HAZARD_CYCLE_GAP_SEC[
                    tof_hazard_pulse_count
                ]
            )
        else:
            tof_hazard_next_transition_time = (
                now + TOF_HAZARD_PULSE_GAP_SEC
            )

        return

    motor_set_direction("CENTER")
    tof_hazard_motor_on = True
    tof_hazard_next_transition_time = (
        now + TOF_HAZARD_PULSE_ON_SEC
    )


def clear_tof_hazard(reason):
    """Drop the active hazard state, stop the warning pattern, and notify the app."""
    global tof_hazard_active
    global tof_hazard_detections
    global tof_hazard_clear_count
    global tof_last_hazard_signature

    tof_hazard_active = False
    tof_hazard_detections = []
    tof_hazard_clear_count = 0
    tof_last_hazard_signature = None

    reset_tof_hazard_pattern()
    motor_stop_all()

    send_tof_hazard(
        "cleared",
        []
    )

    print(
        "[HAZARD] Cleared ->",
        reason
    )


def get_hazard_thresholds_cm():
    """방향 묶음별로 지금 실제로 쓰는 위험 거리(cm). 줄이지 않은 방향은 기본값."""
    return {
        group: (
            hazard_distance_limits_cm[group]
            if hazard_distance_limits_cm[group] is not None
            else HAZARD_DEFAULT_DISTANCE_CM[group]
        )
        for group in HAZARD_DISTANCE_GROUPS
    }


def set_hazard_distance_limit(group, distance_cm):
    """distance_cm이 None이거나 기본값 이상이면 기본값으로 되돌리고, 아니면 최소 10cm로 줄인다."""
    if (
        distance_cm is None
        or distance_cm >= HAZARD_DEFAULT_DISTANCE_CM[group]
    ):
        hazard_distance_limits_cm[group] = None
    else:
        hazard_distance_limits_cm[group] = max(
            HAZARD_MIN_DISTANCE_CM,
            distance_cm
        )


def send_hazard_setting():
    """Report the current hazard options to the app."""
    if smartcane_characteristic is None:
        return

    smartcane_characteristic.send_json(
        {
            "type": "hazard_setting",
            "enabled": hazard_enabled,
            # 방향별로 실제 적용 중인 거리. 예: {"FRONT":120,"SIDE":75,"UPPER":200}
            "thresholds_cm": get_hazard_thresholds_cm(),
        }
    )


def handle_hazard_command(argument):
    """
    HAZARD:ON | HAZARD:OFF | HAZARD:GET
    HAZARD:DIST:<FRONT|SIDE|UPPER>:<cm|DEFAULT>  (한 방향만)
    HAZARD:DIST:<cm|DEFAULT>                    (세 방향 모두)
    """
    global hazard_enabled

    argument = argument.strip().upper()

    if argument == "ON":
        hazard_enabled = True

    elif argument == "OFF":
        hazard_enabled = False
        if tof_hazard_active:
            clear_tof_hazard("disabled by app")

    elif argument.startswith("DIST:"):
        value = argument.split(":", 1)[1].strip()
        groups = HAZARD_DISTANCE_GROUPS

        if ":" in value:
            group, value = [
                part.strip()
                for part in value.split(":", 1)
            ]
            if group not in HAZARD_DISTANCE_GROUPS:
                print("Invalid HAZARD direction:", group)
                send_hazard_setting()
                return
            groups = (group,)

        if value in ("", "DEFAULT", "MAX", "0"):
            parsed = None
        else:
            try:
                parsed = int(round(float(value)))
            except ValueError:
                print("Invalid HAZARD distance:", value)
                send_hazard_setting()
                return

        for group in groups:
            set_hazard_distance_limit(group, parsed)

    elif argument == "GET":
        pass

    else:
        print("Invalid HAZARD command:", argument)
        send_hazard_setting()
        return

    print(
        "[HAZARD] Setting:",
        "enabled=" + str(hazard_enabled),
        " ".join(
            HAZARD_DISTANCE_LABEL_KO[group] + "=" + str(distance_cm) + "cm"
            for group, distance_cm in get_hazard_thresholds_cm().items()
        ),
    )
    send_hazard_setting()


def update_tof_hazard(now):
    """Update hazard state, patterned all-motor warning, and BLE hazard messages."""
    global tof_hazard_active
    global tof_hazard_detections
    global tof_hazard_clear_count
    global tof_last_hazard_signature
    global tof_last_hazard_ble_time

    # 앱에서 위험 감지를 끈 경우: 판정, 진동, BLE 위험 전송을 모두 하지 않는다.
    # ToF 거리값 자체는 계속 읽고 전송하므로 앱 화면의 센서값은 그대로 보인다.
    if not hazard_enabled:
        if tof_hazard_active:
            clear_tof_hazard("disabled by app")
        return False

    detections = get_tof_hazard_detections()

    if detections:
        grouped_detections = group_tof_hazard_detections(
            detections
        )

        signature = tuple(
            detection["position"]
            for detection in grouped_detections
        )
        changed = signature != tof_last_hazard_signature
        newly_active = not tof_hazard_active

        tof_hazard_active = True
        tof_hazard_detections = detections
        tof_hazard_clear_count = 0

        pulse_count = get_tof_hazard_pulse_count(
            detections
        )
        update_tof_hazard_motor_pattern(
            now,
            pulse_count
        )

        should_notify = (
            newly_active
            or changed
            or now - tof_last_hazard_ble_time
            >= TOF_HAZARD_BLE_REPEAT_SEC
        )

        if should_notify:
            send_tof_hazard(
                "detected",
                detections
            )
            tof_last_hazard_ble_time = now
            tof_last_hazard_signature = signature

        if newly_active or changed:
            grouped_detections = group_tof_hazard_detections(
                detections
            )

            labels = [
                TOF_SENSOR_LAYOUT[
                    detection["sensor"] - 1
                ]["label"]
                for detection in grouped_detections
            ]
            nearest = min(
                detection["distance_cm"]
                for detection in detections
            )

            print(
                "[HAZARD] Detected:",
                ", ".join(labels),
                f"| nearest={int(nearest)}cm",
                f"| pattern={pulse_count} pulse(s)",
            )

        return True

    if tof_hazard_active:
        tof_hazard_clear_count += 1

        if (
            tof_hazard_clear_count
            < TOF_HAZARD_CLEAR_READS
        ):
            # Keep the last pattern alive briefly while confirming the obstacle is gone.
            update_tof_hazard_motor_pattern(
                now,
                tof_hazard_pulse_count
            )
            return True

        clear_tof_hazard("returning motor control")

    return False


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

def send_yolo_class_chunks():
    """Send the classes of the loaded YOLO model in BLE-safe chunks."""
    if smartcane_characteristic is None:
        return

    if not yolo_class_names:
        smartcane_characteristic.send_json(
            {
                "type": "object_classes",
                "state": "not_ready",
                "message": "YOLO model is not ready"
            }
        )
        return

    total = (
        len(yolo_class_names)
        + YOLO_CLASSES_PER_BLE_CHUNK
        - 1
    ) // YOLO_CLASSES_PER_BLE_CHUNK
    batch_id = time.time_ns()

    for index in range(total):
        start = index * YOLO_CLASSES_PER_BLE_CHUNK
        end = start + YOLO_CLASSES_PER_BLE_CHUNK

        smartcane_characteristic.send_json(
            {
                "type": "object_classes",
                "state": "chunk",
                "batch": str(batch_id),
                "index": index,
                "total": total,
                "classes": yolo_class_names[start:end]
            }
        )

        # Avoid overwriting notifications too quickly on some BLE adapters.
        time.sleep(0.02)

    print(
        "[YOLO] Sent",
        len(yolo_class_names),
        "classes in",
        total,
        "BLE chunks"
    )

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

    if text.upper() == "GET_CLASSES":
        send_yolo_class_chunks()
        return

    if text.upper().startswith("HAZARD:"):
        handle_hazard_command(
            text.split(
                ":",
                1
            )[1]
        )
        return

    if text.upper().startswith("NAV:"):
        action = text.split(
            ":",
            1
        )[1].strip().upper()

        accepted = start_navigation_motor_cue(
            action
        )

        motor_direction = NAVIGATION_TO_MOTOR_DIRECTION.get(
            action
        )
        channels = DIRECTION_TO_CHANNELS.get(
            motor_direction,
            []
        )
        if accepted:
            motor_state = "activated"
        elif motor_direction is not None and pca is None:
            motor_state = "motor_unavailable"
        else:
            motor_state = "invalid"

        if smartcane_characteristic is not None:
            smartcane_characteristic.send_json(
                {
                    "type": "navigation_motor",
                    "action": action,
                    "direction": motor_direction,
                    "channels": channels,
                    "state": motor_state
                }
            )

        if not accepted:
            print(
                "Invalid NAV command:",
                action
            )
        return

    if text.upper() == "STOP":
        stop_search()
        start_navigation_motor_cue(
            "STOP"
        )

        if smartcane_characteristic is not None:
            smartcane_characteristic.send_json(
                {
                    "type": "search",
                    "state": "stopped"
                }
            )
        return

    if text.startswith("FIND:"):
        requested_target = text.split(
            ":",
            1
        )[1].strip().lower()

        matched_target = next(
            (
                class_name
                for class_name in yolo_class_names
                if class_name.lower() == requested_target
            ),
            None
        )

        if matched_target is not None:
            set_target(matched_target)

            if smartcane_characteristic is not None:
                smartcane_characteristic.send_json(
                    {
                        "type": "search",
                        "state": "started",
                        "target": matched_target
                    }
                )
        else:
            print(
                "Unsupported YOLO target:",
                requested_target
            )

            if smartcane_characteristic is not None:
                smartcane_characteristic.send_json(
                    {
                        "type": "search",
                        "state": "rejected",
                        "target": requested_target,
                        "reason": "unsupported_class"
                    }
                )

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
# Camera setup
# =========================================================

def create_camera():
    picam2 = Picamera2()

    config_kwargs = {
        "main": {
            "size": CAMERA_SIZE,
            "format": CAMERA_FORMAT
        },
        "transform": Transform(
            hflip=CAMERA_HFLIP,
            vflip=CAMERA_VFLIP
        ),
        "queue": CAMERA_QUEUE,
    }

    if CAMERA_SENSOR_SIZE:
        config_kwargs["sensor"] = {
            "output_size": CAMERA_SENSOR_SIZE
        }

    camera_config = (
        picam2.create_preview_configuration(
            **config_kwargs
        )
    )

    picam2.configure(
        camera_config
    )

    cam_controls = {}

    if CAMERA_AUTOFOCUS:
        cam_controls["AfMode"] = controls.AfModeEnum.Continuous
        cam_controls["AfSpeed"] = controls.AfSpeedEnum.Fast
        cam_controls["AfRange"] = controls.AfRangeEnum.Normal

    if CAMERA_METERING_CENTRE:
        cam_controls["AeMeteringMode"] = (
            controls.AeMeteringModeEnum.CentreWeighted
        )

    if CAMERA_HDR:
        cam_controls["HdrMode"] = controls.HdrModeEnum.SingleExposure

    # Skip controls this camera module does not support
    # (e.g. no autofocus on a V2 module) instead of failing at start-up.
    available = set(picam2.camera_controls.keys())

    for name in list(cam_controls.keys()):
        if name not in available:
            print(
                "Camera control not supported, skipped:",
                name
            )
            del cam_controls[name]

    if cam_controls:
        picam2.set_controls(
            cam_controls
        )

    picam2.start()

    time.sleep(1)

    sensor_cfg = picam2.camera_configuration().get("sensor", {})
    print(
        "Camera sensor mode:",
        sensor_cfg.get("output_size"),
        "| AF:", "ON" if "AfMode" in cam_controls else "OFF",
        "| HDR:", "ON" if "HdrMode" in cam_controls else "OFF"
    )

    return picam2


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

        # btmgmt needs a terminal and hangs forever without one. When started
        # by systemd (no TTY) wrap it in a pseudo-terminal via util-linux
        # `script`; `-e` returns the child's exit code, `-q` keeps it quiet.
        if not sys.stdin.isatty():
            full_command = [
                "script",
                "-qec",
                " ".join(full_command),
                "/dev/null"
            ]

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
    global object_motor_active
    global yolo_class_names

    print("")
    print("================================")
    print(" SmartCane Full Integration Test")
    print(" BLE + X120x + 6 ToF + Camera + YOLO + Motor")
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

        if isinstance(model.names, dict):
            yolo_class_names = [
                str(model.names[class_id])
                for class_id in sorted(model.names)
            ]
        else:
            yolo_class_names = [
                str(class_name)
                for class_name in model.names
            ]

        print(
            "YOLO model loaded:",
            len(yolo_class_names),
            "classes"
        )

    if USE_CAMERA:
        print("Starting camera...")

        picam2 = create_camera()

        print("Camera ready")

    last_print_time = 0.0
    last_status_time = 0.0
    last_tof_read_time = 0.0
    last_tof_print_time = 0.0
    last_tof_ble_time = 0.0
    last_found_direction = None
    # Set when a ToF hazard ends so the next detected object direction is
    # re-sent to the app even if it did not change during the hazard.
    hazard_was_active = False

    try:
        while True:
            while glib_context.pending():
                glib_context.iteration(
                    False
                )

            now = time.time()

            update_navigation_motor_cue(now)

            # Hazard just ended: forget the last sent object direction so the
            # app gets the current direction again (voice re-announce).
            if hazard_was_active and not tof_hazard_active:
                last_found_direction = None
            hazard_was_active = tof_hazard_active

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
            # 6 x ToF read / recovery / output
            # ---------------------------------

            if (
                USE_TOF
                and now - last_tof_read_time
                >= TOF_READ_INTERVAL_SEC
            ):
                read_tof_once()
                update_tof_hazard(now)
                last_tof_read_time = now

            if USE_TOF:
                recovered = recover_tof_if_needed()

                if recovered:
                    now = time.time()
                    last_tof_read_time = now
                    last_tof_print_time = now
                    last_tof_ble_time = now
                    update_tof_hazard(now)

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
                object_motor_active = False
                apply_navigation_motor_if_active(now)
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
                object_motor_active = False
                apply_navigation_motor_if_active(now)

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
                    object_motor_active = True
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

                    if not tof_hazard_active:
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
                    object_motor_active = False
                    apply_navigation_motor_if_active(now)
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
