; The policy is deliberately separated from OS side effects so its safety gates are testable.
class FollowIntent {
    __New(serial, generation, now, x, y, monitor, before, beforePid, beforeMin, beforeMonitor) {
        this.Serial := serial, this.Generation := generation, this.Created := now
        this.X := x, this.Y := y, this.Monitor := monitor
        this.Before := before, this.BeforePid := beforePid, this.BeforeMin := beforeMin, this.BeforeMonitor := beforeMonitor
        this.Released := false, this.ReleaseAt := 0, this.Probed := false, this.ProbeSent := false, this.ProbeAt := 0
        this.Kind := "", this.AppId := "", this.Names := []
        this.WaitingForThumbnail := false
        this.StableHwnd := 0, this.StablePid := 0, this.StableAt := 0
        this.MoveConfirmed := false
        this.MovedHwnd := 0, this.MovedPid := 0, this.MovedAt := 0, this.LastAttempt := 0, this.Attempts := 0
        this.Expires := now + 8000
    }
    Release(x, y, now, dragX, dragY, timeout) {
        if Abs(x - this.X) > dragX || Abs(y - this.Y) > dragY || now - this.Created > 1500
            return false
        this.Released := true, this.ReleaseAt := now, this.Expires := now + timeout
        return true
    }
}
class FollowPolicy {
    static Gate(intent, now, serial, generation, enabled, probeTimeout := 1200) {
        if !IsObject(intent)
            return "empty"
        if !enabled || intent.Serial != serial || intent.Generation != generation
            return "cancel"
        if now >= intent.Expires
            return "expired"
        if !intent.Probed
            return now - (intent.ProbeSent ? intent.ProbeAt : intent.Created) > probeTimeout ? "probe-timeout" : "wait"
        if !intent.Released
            return now - intent.Created > 1500 ? "drag-or-hold" : "wait"
        return "ready"
    }
    static Candidate(intent, hwnd, pid, matches, eligible, minimized, now, stableDelay) {
        if !matches || !eligible || minimized || !hwnd || !pid {
            intent.StableHwnd := 0, intent.StablePid := 0
            return false
        }
        if intent.StableHwnd != hwnd || intent.StablePid != pid {
            intent.StableHwnd := hwnd, intent.StablePid := pid, intent.StableAt := now
            return false
        }
        return now - intent.StableAt >= stableDelay
    }
    static MaySettle(intent, now, foreground, pid) {
        return intent.MovedHwnd && foreground = intent.MovedHwnd && pid = intent.MovedPid
            && now - intent.MovedAt <= 1400 && intent.Attempts < 3
            && now - intent.LastAttempt >= 350
    }
}
