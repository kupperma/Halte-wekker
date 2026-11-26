package nl.haltewekker.ride

import android.content.Context
import android.media.AudioDeviceInfo
import android.media.AudioManager
import android.os.Build

/** Sound goes somewhere only you hear it: wired, USB or Bluetooth headphones, or a hearing aid (iOS `privateOutput`). */
object AudioRoute {
    fun privateOutput(context: Context): Boolean {
        val am = context.getSystemService(AudioManager::class.java) ?: return false
        val mine = mutableSetOf(
            AudioDeviceInfo.TYPE_WIRED_HEADSET, AudioDeviceInfo.TYPE_WIRED_HEADPHONES,
            AudioDeviceInfo.TYPE_BLUETOOTH_A2DP, AudioDeviceInfo.TYPE_BLUETOOTH_SCO, AudioDeviceInfo.TYPE_USB_HEADSET,
        )
        if (Build.VERSION.SDK_INT >= 28) mine.add(AudioDeviceInfo.TYPE_HEARING_AID)
        if (Build.VERSION.SDK_INT >= 31) mine.add(AudioDeviceInfo.TYPE_BLE_HEADSET)
        return am.getDevices(AudioManager.GET_DEVICES_OUTPUTS).any { it.type in mine }
    }
}
