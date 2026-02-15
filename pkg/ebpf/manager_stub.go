//go:build !linux

package ebpf

func platformInit() (bool, error) {
	return false, nil
}

func platformCheckRequirements() error {
	return ErrNotSupported
}

func platformLoadProgram(objPath string) (*loadedProgram, error) {
	return nil, ErrNotSupported
}
