package backupcodec

import (
	"encoding/binary"
	"io"
)

func readVLI(data []byte, offset *int) (uint64, error) {
	var value uint64
	for i := 0; i < 9; i++ {
		if *offset >= len(data) {
			return 0, io.ErrUnexpectedEOF
		}
		b := data[*offset]
		*offset++
		value |= uint64(b&127) << uint(i*7)
		if b < 128 {
			return value, nil
		}
	}
	return 0, errInvalid
}

// xz.ReaderConfig.DictCap is a minimum, not a memory limit. Check every
// LZMA2 block and chunk boundary before the decoder can allocate a dictionary.
func validateXZLimits(data []byte, limit int64) error {
	if len(data) < 24 || string(data[:6]) != "\xfd7zXZ\x00" || data[6] != 0 {
		return errInvalid
	}
	checkSize := 0
	switch data[7] {
	case 0:
	case 1:
		checkSize = 4
	case 4:
		checkSize = 8
	case 10:
		checkSize = 32
	default:
		return errInvalid
	}
	offset := 12
	var expanded int64
	for offset < len(data)-12 {
		if data[offset] == 0 {
			return nil
		}
		headerEnd := offset + (int(data[offset])+1)*4
		if headerEnd > len(data)-12 || headerEnd < offset+8 {
			return errInvalid
		}
		header := data[offset : headerEnd-4]
		flags := header[1]
		if flags & ^byte(0xc0) != 0 {
			return errInvalid
		}
		pos := 2
		for _, bit := range []byte{0x40, 0x80} {
			if flags&bit != 0 {
				if _, err := readVLI(header, &pos); err != nil {
					return errInvalid
				}
			}
		}
		filter, err := readVLI(header, &pos)
		if err != nil || filter != 0x21 {
			return errInvalid
		}
		size, err := readVLI(header, &pos)
		if err != nil || size != 1 || pos >= len(header) {
			return errInvalid
		}
		if header[pos] > 24 {
			return errTooLarge
		}
		pos = headerEnd
		for {
			if pos >= len(data)-12 {
				return errInvalid
			}
			control := data[pos]
			if control == 0 {
				pos++
				break
			}
			headerSize := 3
			if control >= 0x80 {
				headerSize = 5
				if control >= 0xc0 {
					headerSize = 6
				}
			} else if control != 1 && control != 2 {
				return errInvalid
			}
			if pos+headerSize > len(data)-12 {
				return errInvalid
			}
			unpacked := int64(binary.BigEndian.Uint16(data[pos+1:pos+3])) + 1
			packed := int(unpacked)
			if control >= 0x80 {
				unpacked += int64(control&31) << 16
				packed = int(binary.BigEndian.Uint16(data[pos+3:pos+5])) + 1
			}
			expanded += unpacked
			if expanded > limit {
				return errTooLarge
			}
			pos += headerSize + packed
			if pos > len(data)-12 {
				return errInvalid
			}
		}
		padding := (-(pos - headerEnd)) & 3
		offset = pos + padding + checkSize
	}
	return errInvalid
}
