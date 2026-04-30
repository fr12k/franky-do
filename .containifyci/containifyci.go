//go:generate sh -c "if [ ! -f go.mod ]; then echo 'Initializing go.mod...'; go mod init .containifyci; else echo 'go.mod already exists. Skipping initialization.'; fi"
//go:generate go get github.com/containifyci/engine-ci/protos2
//go:generate go get github.com/containifyci/engine-ci/client
//go:generate go mod tidy

package main

import (
	"os"

	"github.com/containifyci/engine-ci/client/pkg/build"
	"github.com/containifyci/engine-ci/protos2"
)

func main() {
	os.Chdir("../")
	// Static fallback configuration
	opts := build.NewServiceBuild("franky-do", protos2.BuildType_Zig)
	opts.Verbose = false
	opts.Folder = "./"
	opts.Image = ""
	opts.Properties = map[string]*build.ListValue{
		"goreleaser": build.NewList("true"),
		"optimize": build.NewList("ReleaseFast"),
	}
	//TODO: adjust the registry to your own container registry
	opts.Registry = "containifyci"
	build.Build(opts)
}
