package utils

import "time"

func HumanDuration(d time.Duration) string {
	if d < time.Minute {
		return d.Truncate(time.Second).String()
	}
	if d < time.Hour {
		m := int(d.Minutes())
		s := int(d.Seconds()) % 60
		return fmt2(m, "m", s, "s")
	}
	h := int(d.Hours())
	m := int(d.Minutes()) % 60
	return fmt2(h, "h", m, "m")
}

func fmt2(a int, as string, b int, bs string) string {
	return itoa(a) + as + itoa(b) + bs
}

func itoa(v int) string {
	if v == 0 {
		return "0"
	}
	neg := false
	if v < 0 {
		neg = true
		v = -v
	}
	buf := [20]byte{}
	i := len(buf)
	for v > 0 {
		i--
		buf[i] = byte('0' + v%10)
		v /= 10
	}
	if neg {
		i--
		buf[i] = '-'
	}
	return string(buf[i:])
}
