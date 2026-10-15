# AI Smart Cane

시각장애인의 안전한 이동과 주변 객체 탐색을 지원하기 위한  
AI 기반 스마트 지팡이 프로젝트입니다.

Raspberry Pi 5를 중심으로 카메라 객체 인식, ToF 장애물 감지,
진동 모터 피드백, BLE 통신, 배터리 상태 모니터링 기능을 구현합니다.

## Main Features

### 1. AI Object Detection

- Raspberry Pi Camera 사용
- YOLOv8 기반 객체 인식
- 입력 해상도: 640x480
- YOLO 입력: 640x640 Letterbox
- 목표 객체 탐색
- 동일 객체가 여러 개 탐지될 경우 가장 높은 Confidence 객체 선택

### 2. 3x3 Object Direction Detection

카메라 화면을 3x3 영역으로 나누어 객체의 위치를 판단합니다.

```text
TOP+LEFT       TOP        TOP+RIGHT

LEFT           CENTER     RIGHT

BOTTOM+LEFT    BOTTOM     BOTTOM+RIGHT
```

탐지된 객체의 Bounding Box 중심점을 기준으로 방향을 결정합니다.

### 3. Haptic Motor Feedback

PCA9685를 이용하여 4개의 진동 모터를 제어합니다.

```text
CH0 -> TOP
CH1 -> LEFT
CH2 -> BOTTOM
CH3 -> RIGHT
```

대각선 방향은 두 개의 모터를 동시에 동작시킵니다.

예:

```text
TOP+LEFT
-> TOP + LEFT motor

BOTTOM+RIGHT
-> BOTTOM + RIGHT motor

CENTER
-> All 4 motors
```

### 4. ToF Obstacle Detection

VL53L1X ToF 센서 8개를 사용합니다.

I2C Address:

```text
ToF 1 -> 0x2A
ToF 2 -> 0x2B
ToF 3 -> 0x2C
ToF 4 -> 0x2D
ToF 5 -> 0x2E
ToF 6 -> 0x2F
ToF 7 -> 0x30
ToF 8 -> 0x31
```

XSHUT GPIO:

```text
ToF 1 -> GPIO17
ToF 2 -> GPIO27
ToF 3 -> GPIO22
ToF 4 -> GPIO23
ToF 5 -> GPIO24
ToF 6 -> GPIO25
ToF 7 -> GPIO5
ToF 8 -> GPIO26
```

센서 통신 오류가 연속으로 발생할 경우
ToF 센서를 자동으로 재초기화하는 Recovery 기능을 포함합니다.

### 5. BLE Communication

스마트폰 앱과 Raspberry Pi 간 통신에 Bluetooth Low Energy를 사용합니다.

Supported Commands:

```text
PING
STATUS
STOP
FIND:<target>
```

Example:

```text
FIND:cell phone
```

스마트폰에서 탐색할 객체를 전달하면 Raspberry Pi가
YOLO를 이용하여 해당 객체를 탐색합니다.

### 6. Battery Monitoring

X120x 전원 모듈을 이용하여 시스템 상태를 확인합니다.

Monitoring Data:

- Battery percentage
- Battery voltage
- Charging status
- Input voltage
- CPU voltage
- CPU current
- CPU temperature
- Power consumption
- Fan RPM
- Power status

## System Flow

```text
Smartphone App
      |
      | BLE
      v
Raspberry Pi 5
      |
      +-------------------------+
      |                         |
      v                         v
   Camera                    8 ToF
      |                      Sensors
      v
    YOLO
      |
      v
Target Detection
      |
      v
3x3 Direction
      |
      v
PCA9685
      |
      v
4 Vibration Motors
```

## Project Structure

```text
AI-Smart-Cane/
|
├── battery/
│   └── Battery and X120x monitoring
│
├── ble/
│   └── Bluetooth Low Energy communication
│
├── main/
│   └── smartcane_full_integration.py
│
├── models/
│   └── AI model related files
│
├── motor/
│   ├── direction_motor.py
│   ├── motor_test.py
│   └── pca9685_test.py
│
├── tof/
│   ├── tof_address_setup.py
│   ├── tof_multi_test.py
│   └── tof_recovery_test.py
│
├── vision/
│   ├── camera_test.py
│   ├── yolo_test.py
│   └── target_detection.py
│
├── .gitignore
└── README.md
```

## Main Integration Program

전체 시스템 통합 실행 파일:

```text
main/smartcane_full_integration.py
```

통합 기능:

```text
BLE
+
X120x Battery Monitoring
+
8 ToF Sensors
+
ToF Automatic Recovery
+
Raspberry Pi Camera
+
YOLO Object Detection
+
3x3 Direction Detection
+
4 Motor Haptic Feedback
```

## Hardware

Main Hardware:

- Raspberry Pi 5
- Raspberry Pi Camera
- VL53L1X ToF Sensor x8
- PCA9685
- Vibration Motor x4
- MOSFET Motor Driver Circuit
- X120x Raspberry Pi Power Module

## Software

Main Software / Libraries:

- Python
- OpenCV
- Ultralytics YOLO
- Picamera2
- Adafruit VL53L1X
- Adafruit PCA9685
- BlueZ / D-Bus
- GPIOZero
- SMBus2

## YOLO Model

Default model:

```text
yolov8n.pt
```

YOLO model files are excluded from Git using `.gitignore`.

The model must be installed or placed on the Raspberry Pi before running
the object detection program.

## Running the Integration Program

Move to the project directory.

```bash
cd AI-Smart-Cane
```

Run:

```bash
python3 main/smartcane_full_integration.py
```

## Git Branch Strategy

```text
main
 ├── feature/battery
 ├── feature/motor
 ├── feature/tof
 ├── feature/vision
 ├── feature/ble
 └── feature/integration
```

Development is performed in feature branches.

After completing and testing each feature:

```text
Feature Branch
      ↓
Pull Request
      ↓
Code Review
      ↓
main
```

## Project Goal

본 프로젝트는 카메라 기반 AI 객체 인식과 거리 센서를 활용하여
시각장애인의 주변 환경 인지 및 안전한 이동을 지원하는 것을 목표로 합니다.

탐지된 객체의 위치를 진동 패턴으로 사용자에게 전달하고,
스마트폰 애플리케이션과 연동하여 객체 탐색 및 상태 확인 기능을 제공합니다.
