module github.com/sameehj/kai

go 1.24.0

toolchain go1.24.9

require (
	github.com/cilium/ebpf v0.20.0
	github.com/sirupsen/logrus v1.9.3
	github.com/spf13/cobra v1.10.1
	gopkg.in/yaml.v3 v3.0.1
)

require (
	github.com/inconshreveable/mousetrap v1.1.0 // indirect
	github.com/spf13/pflag v1.0.9 // indirect
	golang.org/x/sys v0.37.0 // indirect
)

replace github.com/sameehj/kai => ./
