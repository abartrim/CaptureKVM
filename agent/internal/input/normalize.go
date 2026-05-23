package input

func ClampMouseDelta(v int) int8 {
	switch {
	case v > 127:
		return 127
	case v < -127:
		return -127
	default:
		return int8(v)
	}
}
