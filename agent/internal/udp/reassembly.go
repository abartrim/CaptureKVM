package udp

type replayWindow struct {
	initialized bool
	highest     uint32
	seen        uint64
}

func (w *replayWindow) Accept(seq uint32) bool {
	if !w.initialized {
		w.initialized = true
		w.highest = seq
		w.seen = 1
		return true
	}
	if seq > w.highest {
		shift := seq - w.highest
		if shift >= 64 {
			w.seen = 0
		} else {
			w.seen <<= shift
		}
		w.highest = seq
		w.seen |= 1
		return true
	}
	diff := w.highest - seq
	if diff >= 64 {
		return false
	}
	mask := uint64(1) << diff
	if w.seen&mask != 0 {
		return false
	}
	w.seen |= mask
	return true
}
