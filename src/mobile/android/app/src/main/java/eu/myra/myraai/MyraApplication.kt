package eu.myra.myraai

import android.app.Application
import android.app.NotificationChannel
import android.app.NotificationManager
import android.os.Build
import android.util.Log

/**
 * MyraApplication — application singleton.
 *
 * Created before any Activity, Service, or BroadcastReceiver. We use it to
 * register notification channels, which must exist before the first
 * notification is posted (including the first FCM-triggered one). Doing it
 * here, rather than in MainActivity.onCreate, guarantees correctness even
 * when a push arrives while the app process is being cold-started in the
 * background.
 *
 * Channel IDs are kept in `strings.xml` so they can be referenced from the
 * AndroidManifest.xml `default_notification_channel_id` meta-data and from
 * MyraFirebaseMessagingService.
 */
class MyraApplication : Application() {

    override fun onCreate() {
        super.onCreate()
        registerNotificationChannels()
    }

    private fun registerNotificationChannels() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return  // Channels are API 26+ only.
        val nm = getSystemService(NotificationManager::class.java) ?: return

        val general = NotificationChannel(
            getString(R.string.notification_channel_general),
            getString(R.string.notification_channel_general_name),
            NotificationManager.IMPORTANCE_DEFAULT,
        ).apply {
            description = getString(R.string.notification_channel_general_description)
        }

        // HIGH importance for chat replies — these need to bypass Doze and
        // show as heads-up so the user sees them while the app is backgrounded.
        val chat = NotificationChannel(
            getString(R.string.notification_channel_chat),
            getString(R.string.notification_channel_chat_name),
            NotificationManager.IMPORTANCE_HIGH,
        ).apply {
            description = getString(R.string.notification_channel_chat_description)
        }

        nm.createNotificationChannels(listOf(general, chat))
        Log.d("MyraApplication", "Registered notification channels: general, chat_replies")
    }
}
