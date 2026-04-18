pub const EmbeddedTemplates = struct {
    pub const layout: []const u8 = @embedFile("../../examples/embed_templates/src/views/layout.html");
    pub const index: []const u8 = @embedFile("../../examples/embed_templates/src/views/index.html");
};
