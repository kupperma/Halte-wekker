# Ideas for later

Travel comes first. These wait until the travel part is great.

## Later

- **Things to do in the city you're in:** recommendations for places and activities in the city you travel to or are in (food, study spots, events, sights). Student-friendly, with the travel times from where you are.
- **Workouts:** parked (history at a4539f2; restore with `git checkout a4539f2 -- ios/App/Workout*`).
- **Recomp (weight loss):** on the back burner; its data is kept.
- **Setup for other students:** make the app usable by any uni or college student (their own school, schedule and places).

- **Android version (after Friends):** so Android friends can use the app and be friends with iPhone users through
  the same relay and encrypted boxes. Likely a native Kotlin (Jetpack Compose) app; free to share as an APK from the
  GitHub releases, built on Linux CI (no Mac needed). The Friends box format is kept platform-neutral for this.

- **Friends extras (after the Android version, on both apps):**
  1. "Wait for me": a friend sees how far you are from the stop and can wait or take the next ride with you.
  2. Delay alarm for shared rides: everyone on a shared ride hears about a delay or cancellation, with the next ride
     you can all take.
  3. Wake-up buddy: "Lisa isn't moving yet" when a friend hasn't left by their planned time (opt-in by that friend).
  4. Who's on campus (opt-in): which friends are at school now.
  5. Free hours together, from the shared timetables.
  6. Live link for people without the app (e.g. parents): a web page with your trip's live ETA, ending on arrival.
  7. Friends leaderboard (fastest trips, rides together).
  8. Ride history ("you rode together 14 times this month").

## Order (decided 2026-11-18)

Friends 0.25 to 0.28, then the Android version, then the Friends extras on both. Build without asking the user;
they review afterwards.

## Travel (now)

- Trip screen: make clear which stop or platform to go to and how to walk there (concepts S1–S3 on the design canvas).
- Tune the real-GPS matcher values from field logs (freshness, advance, fast lane).
