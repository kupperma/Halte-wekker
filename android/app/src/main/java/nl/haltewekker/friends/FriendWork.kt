package nl.haltewekker.friends

import android.content.Context
import androidx.work.Constraints
import androidx.work.CoroutineWorker
import androidx.work.ExistingPeriodicWorkPolicy
import androidx.work.NetworkType
import androidx.work.PeriodicWorkRequestBuilder
import androidx.work.WorkManager
import androidx.work.WorkerParameters
import java.util.concurrent.TimeUnit

/**
 * The Friends background check (iOS: the school alarm's background refresh): WorkManager, about once an hour with a
 * network, only while there's an account with someone in the list (a friend, or a request either way). It sends what's
 * waiting and reads the mailbox; new lines become one notification per chat. No push, no loop of its own.
 */
object FriendWork {
    private const val NAME = "friends-refresh"

    fun update(c: Context) {
        val wm = try { WorkManager.getInstance(c) } catch (_: Exception) { return }
        val b = FriendStore.book.value
        val someone = FriendStore.hasAccount && b != null && (b.friends.isNotEmpty() || b.incoming.isNotEmpty() || b.outgoing.isNotEmpty())
        if (!someone) { wm.cancelUniqueWork(NAME); return }
        wm.enqueueUniquePeriodicWork(NAME, ExistingPeriodicWorkPolicy.KEEP,
            PeriodicWorkRequestBuilder<FriendWorker>(1, TimeUnit.HOURS, 20, TimeUnit.MINUTES)
                .setConstraints(Constraints.Builder().setRequiredNetworkType(NetworkType.CONNECTED).build()).build())
    }
}

class FriendWorker(context: Context, params: WorkerParameters) : CoroutineWorker(context, params) {
    override suspend fun doWork(): Result {
        FriendStore.init(applicationContext)
        try { FriendStore.syncAndWait(FriendStore.Why.AUTO) } catch (_: Exception) {}
        return Result.success()
    }
}
