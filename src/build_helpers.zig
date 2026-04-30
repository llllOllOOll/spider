const std = @import("std");

/// Configura automaticamente o Spider no projeto do dev.
/// Detecta spider.config.zig e embedded_templates.zig automaticamente.
/// Chama no build.zig do dev:
///   const spider_build = @import("spider_build");
///   spider_build.setup(b, exe, spider_dep);
pub fn setup(
    b: *std.Build,
    exe: *std.Build.Step.Compile,
    spider_dep: *std.Build.Dependency,
) void {
    // 1. detectar e registrar spider.config.zig
    if (b.pathExists("spider.config.zig")) {
        exe.root_module.addAnonymousImport("spider_config", .{
            .root_source_file = b.path("spider.config.zig"),
        });
    }

    // 2. rodar generate-templates automaticamente
    const gen = b.addRunArtifact(spider_dep.artifact("generate-templates"));
    gen.addArg("src/");
    gen.addArg("src/embedded_templates.zig");
    exe.step.dependOn(&gen.step);

    // 3. registrar embedded_templates.zig se existir após geração
    // NOTA: não podemos verificar se existe antes de gerar
    // registrar sempre — o generate-templates sempre cria o arquivo
    exe.root_module.addAnonymousImport("spider_templates", .{
        .root_source_file = b.path("src/embedded_templates.zig"),
    });
}
