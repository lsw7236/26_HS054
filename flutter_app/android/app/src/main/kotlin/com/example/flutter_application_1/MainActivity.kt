package com.example.flutter_application_1

import android.content.Context
import android.media.AudioManager
import android.os.Handler
import android.os.Looper
import android.util.Log
import android.view.KeyEvent
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {

    companion object {
        private const val TAG = "SmartCaneKey"
        private const val CHANNEL = "smartcane/hardware_key"
        private const val LONG_PRESS_MS = 800L
    }

    private lateinit var hardwareKeyChannel: MethodChannel
    private val handler = Handler(Looper.getMainLooper())

    private var volumeUpPressed = false
    private var volumeUpLongTriggered = false

    private var volumeDownPressed = false
    private var volumeDownLongTriggered = false

    private val volumeUpLongRunnable = Runnable {
        if (volumeUpPressed && !volumeUpLongTriggered) {
            triggerVolumeUpLongPress("handler")
        }
    }

    private val volumeDownLongRunnable = Runnable {
        if (volumeDownPressed && !volumeDownLongTriggered) {
            triggerVolumeDownLongPress("handler")
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        hardwareKeyChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            CHANNEL
        )

        Log.d(TAG, "MethodChannel ready: $CHANNEL")
    }

    override fun dispatchKeyEvent(event: KeyEvent): Boolean {
        if (event.keyCode == KeyEvent.KEYCODE_VOLUME_UP ||
            event.keyCode == KeyEvent.KEYCODE_VOLUME_DOWN
        ) {
            Log.d(
                TAG,
                "dispatchKeyEvent key=${event.keyCode} action=${event.action} repeat=${event.repeatCount}"
            )
        }

        when (event.keyCode) {
            KeyEvent.KEYCODE_VOLUME_UP -> {
                when (event.action) {
                    KeyEvent.ACTION_DOWN -> {
                        if (!volumeUpPressed) {
                            volumeUpPressed = true
                            volumeUpLongTriggered = false
                            handler.removeCallbacks(volumeUpLongRunnable)
                            handler.postDelayed(volumeUpLongRunnable, LONG_PRESS_MS)

                            Log.d(TAG, "VOLUME_UP down: long-press timer started")
                        }

                        // 일부 단말은 장시간 누르면 repeatCount만 증가시키므로
                        // repeat 이벤트도 보조 long-press 트리거로 사용한다.
                        if (event.repeatCount >= 2 && !volumeUpLongTriggered) {
                            triggerVolumeUpLongPress("repeat")
                        }

                        return true
                    }

                    KeyEvent.ACTION_UP -> {
                        handler.removeCallbacks(volumeUpLongRunnable)

                        val wasLongPress = volumeUpLongTriggered

                        volumeUpPressed = false
                        volumeUpLongTriggered = false

                        Log.d(TAG, "VOLUME_UP up: long=$wasLongPress")

                        if (!wasLongPress) {
                            adjustMediaVolume(AudioManager.ADJUST_RAISE)
                        }

                        return true
                    }
                }
            }

            KeyEvent.KEYCODE_VOLUME_DOWN -> {
                when (event.action) {
                    KeyEvent.ACTION_DOWN -> {
                        if (!volumeDownPressed) {
                            volumeDownPressed = true
                            volumeDownLongTriggered = false
                            handler.removeCallbacks(volumeDownLongRunnable)
                            handler.postDelayed(
                                volumeDownLongRunnable,
                                LONG_PRESS_MS
                            )

                            Log.d(TAG, "VOLUME_DOWN down: long-press timer started")
                        }

                        // Handler가 어떤 이유로 실행되지 않는 단말에서도
                        // 반복 key-down이 들어오면 long press를 한 번만 실행한다.
                        if (event.repeatCount >= 2 && !volumeDownLongTriggered) {
                            triggerVolumeDownLongPress("repeat")
                        }

                        return true
                    }

                    KeyEvent.ACTION_UP -> {
                        handler.removeCallbacks(volumeDownLongRunnable)

                        val wasLongPress = volumeDownLongTriggered

                        volumeDownPressed = false
                        volumeDownLongTriggered = false

                        Log.d(TAG, "VOLUME_DOWN up: long=$wasLongPress")

                        if (!wasLongPress) {
                            adjustMediaVolume(AudioManager.ADJUST_LOWER)
                        }

                        return true
                    }
                }
            }
        }

        return super.dispatchKeyEvent(event)
    }

    private fun triggerVolumeUpLongPress(source: String) {
        if (volumeUpLongTriggered) return

        volumeUpLongTriggered = true
        handler.removeCallbacks(volumeUpLongRunnable)

        Log.d(TAG, "VOLUME_UP LONG triggered by $source")

        if (::hardwareKeyChannel.isInitialized) {
            hardwareKeyChannel.invokeMethod("volumeUpLongPressed", null)
        } else {
            Log.e(TAG, "MethodChannel not initialized for VOLUME_UP")
        }
    }

    private fun triggerVolumeDownLongPress(source: String) {
        if (volumeDownLongTriggered) return

        volumeDownLongTriggered = true
        handler.removeCallbacks(volumeDownLongRunnable)

        Log.d(TAG, "VOLUME_DOWN LONG triggered by $source")

        if (::hardwareKeyChannel.isInitialized) {
            hardwareKeyChannel.invokeMethod("volumeDownLongPressed", null)
        } else {
            Log.e(TAG, "MethodChannel not initialized for VOLUME_DOWN")
        }
    }

    private fun adjustMediaVolume(direction: Int) {
        val audioManager =
            getSystemService(Context.AUDIO_SERVICE) as AudioManager

        audioManager.adjustStreamVolume(
            AudioManager.STREAM_MUSIC,
            direction,
            AudioManager.FLAG_SHOW_UI
        )
    }

    override fun onPause() {
        handler.removeCallbacks(volumeUpLongRunnable)
        handler.removeCallbacks(volumeDownLongRunnable)

        volumeUpPressed = false
        volumeUpLongTriggered = false
        volumeDownPressed = false
        volumeDownLongTriggered = false

        super.onPause()
    }

    override fun onDestroy() {
        handler.removeCallbacks(volumeUpLongRunnable)
        handler.removeCallbacks(volumeDownLongRunnable)
        super.onDestroy()
    }
}
