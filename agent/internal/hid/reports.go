package hid

func CRC8(data []byte) byte {
	var crc byte
	for _, b := range data {
		crc ^= b
		for range 8 {
			if crc&0x80 != 0 {
				crc = (crc << 1) ^ 0x07
			} else {
				crc <<= 1
			}
		}
	}
	return crc
}

func COBSEncode(input []byte) []byte {
	out := make([]byte, 1, len(input)+2)
	codeIndex := 0
	code := byte(1)
	for _, b := range input {
		if b == 0 {
			out[codeIndex] = code
			codeIndex = len(out)
			out = append(out, 0)
			code = 1
			continue
		}
		out = append(out, b)
		code++
		if code == 0xFF {
			out[codeIndex] = code
			codeIndex = len(out)
			out = append(out, 0)
			code = 1
		}
	}
	out[codeIndex] = code
	return out
}

func Frame(frameType byte, payload []byte) []byte {
	raw := make([]byte, 0, 2+len(payload))
	raw = append(raw, frameType)
	raw = append(raw, payload...)
	raw = append(raw, CRC8(raw))
	framed := COBSEncode(raw)
	return append(framed, 0x00)
}
