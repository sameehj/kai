package tools

func RegisterBuiltins(r *Registry) {
	_ = r.Register(execTool{})
	_ = r.Register(readTool{})
	_ = r.Register(writeTool{})
	_ = r.Register(searchTool{})
	_ = r.Register(reportTool{})
}
