pub const EmbeddedTemplates = struct {
    layout: []const u8 = @embedFile("views/layout.html"),
    home_index: []const u8 = @embedFile("views/home/index.html"),
};
