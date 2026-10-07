//! Helper executable for `zig build sample-files`: writes workbooks for
//! checking by hand in Excel, Google Sheets and Numbers — the programs
//! the automated tests cannot drive.
//!
//!     sample_files <output-dir>
//!
//! Three files, always the same bytes:
//!
//! - `1-tudo-um-pouco.xlsx`: every feature of the module at least once.
//! - `2-enquete.xlsx`: what a poll export looks like, about 200 rows.
//! - `3-limites.xlsx`: a cell at the text limit, a sheet name at the
//!   name limit, a value in the very last cell of a sheet.
//!
//! All names and data are made up. The cell text is Portuguese on
//! purpose: accents are part of what is being checked.

const std = @import("std");
const xlsx = @import("xlsx");

const header: xlsx.Style = .{ .bold = true, .fill = 0xDCE6F1, .border = .thin };
const br_date: xlsx.Style = .{ .number_format = .{ .custom = "dd/mm/yyyy" } };
const br_datetime: xlsx.Style = .{ .number_format = .{ .custom = "dd/mm/yyyy hh:mm" } };

fn text(value: []const u8) xlsx.Value {
    return .{ .text = value };
}

fn everything(gpa: std.mem.Allocator) !*xlsx.Workbook {
    const wb = try xlsx.Workbook.init(gpa);
    errdefer wb.deinit();

    const overview = try wb.addSheet("Visão geral");
    try overview.setColumnWidth(0, 34);
    try overview.setColumnWidth(1, 44);
    try overview.setColumnWidth(2, 50);
    try overview.setRow(0, 0, &.{ text("O que é"), text("Valor"), text("O que você deve ver") }, header);
    const rows = [_][3]xlsx.Value{
        .{ text("Texto com acentos"), text("Ação, coração, pão de queijo, à vista"), text("Os acentos aparecem certos") },
        .{ text("Texto com emoji"), text("Aprovado ✅ 🎉 😀"), text("Os três emojis aparecem") },
        .{ text("Texto que começa com ="), text("=SOMA(1;2)"), text("Aparece o texto =SOMA(1;2), não o número 3") },
        .{ text("Texto que começa com +"), text("+55 11 99999-0000"), text("Aparece o telefone inteiro, como texto") },
        .{ text("Texto com aspas e sinais"), text("Ele disse \"oi\" & saiu <cedo>"), text("Aspas, & e < > aparecem como estão") },
        .{ text("Texto em duas linhas"), text("primeira linha\nsegunda linha"), text("Duas linhas na mesma célula (talvez precise aumentar a altura)") },
        .{ text("Número que é texto"), text("00123"), text("Aparece 00123, com os zeros, alinhado à esquerda") },
        .{ text("Verdadeiro"), .{ .boolean = true }, text("VERDADEIRO (ou TRUE)") },
        .{ text("Falso"), .{ .boolean = false }, text("FALSO (ou FALSE)") },
    };
    for (rows, 1..) |row, index| try overview.setRow(@intCast(index), 0, &row, .{});
    try overview.freeze(1, 0);
    try overview.setAutoFilter(.{ .first_row = 0, .first_col = 0, .last_row = rows.len, .last_col = 2 });

    const numbers = try wb.addSheet("Números e datas");
    try numbers.setColumnWidth(0, 34);
    try numbers.setColumnWidth(1, 22);
    try numbers.setColumnWidth(2, 50);
    try numbers.setRow(0, 0, &.{ text("O que é"), text("Valor"), text("O que você deve ver") }, header);
    try numbers.freeze(1, 1);

    try numbers.set(1, 0, text("Inteiro"));
    try numbers.set(1, 1, .int(42));
    try numbers.set(1, 2, text("42"));
    try numbers.set(2, 0, text("Decimal"));
    try numbers.set(2, 1, .{ .number = 3.14159 });
    try numbers.set(2, 2, text("3,14159"));
    try numbers.set(3, 0, text("Duas casas"));
    try numbers.setStyled(3, 1, .{ .number = 1234.5 }, .{ .number_format = .decimal });
    try numbers.set(3, 2, text("1234,50"));
    try numbers.set(4, 0, text("Milhar e duas casas"));
    try numbers.setStyled(4, 1, .{ .number = 1234567.891 }, .{ .number_format = .thousands_decimal });
    try numbers.set(4, 2, text("1.234.567,89"));
    try numbers.set(5, 0, text("Negativo"));
    try numbers.setStyled(5, 1, .{ .number = -1250.5 }, .{ .number_format = .thousands_decimal });
    try numbers.set(5, 2, text("-1.250,50"));
    try numbers.set(6, 0, text("Percentual"));
    try numbers.setStyled(6, 1, .{ .number = 0.375 }, .{ .number_format = .percent_decimal });
    try numbers.set(6, 2, text("37,50%"));
    try numbers.set(7, 0, text("Percentual inteiro"));
    try numbers.setStyled(7, 1, .{ .number = 0.75 }, .{ .number_format = .percent });
    try numbers.set(7, 2, text("75%"));
    try numbers.set(8, 0, text("Data (formato do programa)"));
    try numbers.set(8, 1, .{ .date = .{ .year = 2026, .month = 10, .day = 7 } });
    try numbers.set(8, 2, text("7 de outubro de 2026, no formato de data do seu programa"));
    try numbers.set(9, 0, text("Data (dd/mm/aaaa)"));
    try numbers.setStyled(9, 1, .{ .date = .{ .year = 2026, .month = 10, .day = 7 } }, br_date);
    try numbers.set(9, 2, text("07/10/2026"));
    try numbers.set(10, 0, text("Data e hora (formato do programa)"));
    try numbers.set(10, 1, .{ .datetime = .{ .year = 2026, .month = 10, .day = 7, .hour = 14, .minute = 30 } });
    try numbers.set(10, 2, text("7 de outubro de 2026, 14:30"));
    try numbers.set(11, 0, text("Data e hora (dd/mm/aaaa hh:mm)"));
    try numbers.setStyled(11, 1, .{ .datetime = .{ .year = 2026, .month = 10, .day = 7, .hour = 14, .minute = 30 } }, br_datetime);
    try numbers.set(11, 2, text("07/10/2026 14:30"));
    try numbers.set(12, 0, text("Hora"));
    try numbers.setStyled(12, 1, .{ .datetime = .{ .year = 1900, .month = 1, .day = 1, .hour = 9, .minute = 5, .second = 30 } }, .{ .number_format = .time });
    try numbers.set(12, 2, text("9:05:30"));
    try numbers.set(13, 0, text("Fórmula: soma de B2 e B3"));
    try numbers.set(13, 1, .{ .formula = "SUM(B2:B3)" });
    try numbers.set(13, 2, text("45,14159"));
    try numbers.set(14, 0, text("Fórmula: condição"));
    try numbers.set(14, 1, .{ .formula = "IF(B2>40,\"maior\",\"menor\")" });
    try numbers.set(14, 2, text("maior"));

    try numbers.set(16, 0, text("Cor de fundo amarela"));
    try numbers.setStyled(16, 1, text("amarelo"), .{ .fill = 0xFFFF00 });
    try numbers.set(17, 0, text("Cor de fundo verde, negrito"));
    try numbers.setStyled(17, 1, text("verde"), .{ .fill = 0xC6EFCE, .bold = true });
    try numbers.set(19, 0, text("Borda fina"));
    try numbers.setStyled(19, 1, text("fina"), .{ .border = .thin });
    try numbers.set(21, 0, text("Borda média"));
    try numbers.setStyled(21, 1, text("média"), .{ .border = .medium });
    try numbers.set(23, 0, text("Borda grossa"));
    try numbers.setStyled(23, 1, text("grossa"), .{ .border = .thick });

    const layout = try wb.addSheet("Aparência");
    const layout_widths = [_]f64{ 12, 12, 40, 26 };
    for (layout_widths, 0..) |width, col| try layout.setColumnWidth(@intCast(col), width);
    const boxed: xlsx.Style = .{ .font_name = "Times New Roman", .font_size = 10, .border = .thin, .v_align = .center };
    var title = boxed;
    title.bold = true;
    title.font_size = 14;
    title.h_align = .center;
    try layout.setRow(0, 0, &.{ text("CADASTRO DE EXEMPLO — TÍTULO MESCLADO E CENTRALIZADO"), .blank, .blank, .blank }, title);
    try layout.mergeCells(.{ .first_row = 0, .first_col = 0, .last_row = 0, .last_col = 3 });
    try layout.setRowHeight(0, 30);
    var column_title = boxed;
    column_title.bold = true;
    column_title.fill = 0xD7E4BD;
    column_title.h_align = .center;
    try layout.setRow(1, 0, &.{ text("Quadra"), text("Lote"), text("Nome"), text("Telefone") }, column_title);
    var centered = boxed;
    centered.h_align = .center;
    var wrapped = boxed;
    wrapped.wrap = true;
    var right = boxed;
    right.h_align = .right;
    try layout.setStyled(2, 0, text("A"), centered);
    try layout.setStyled(2, 1, .int(12), centered);
    try layout.setStyled(2, 2, text("Texto comprido que não cabe na largura da coluna e por isso quebra em várias linhas dentro da célula"), wrapped);
    try layout.setStyled(2, 3, text("(11) 91234-5678\n(11) 3456-7890"), wrapped);
    try layout.setRowHeight(2, 52);
    try layout.setStyled(3, 0, text("B"), centered);
    try layout.setStyled(3, 1, .int(7), centered);
    try layout.setStyled(3, 2, text("Alinhado à direita"), right);
    try layout.setStyled(3, 3, .blank, boxed);
    try layout.setStyled(5, 2, text("Itálico"), .{ .italic = true });
    try layout.setStyled(6, 2, text("Sublinhado e azul"), .{ .underline = true, .font_color = 0x0000FF });
    try layout.setStyled(7, 2, text("Vermelho, negrito, tamanho 16"), .{ .bold = true, .font_color = 0xC00000, .font_size = 16 });
    try layout.setStyled(8, 2, text("Fonte Courier New"), .{ .font_name = "Courier New" });
    try layout.setStyled(9, 2, text("No alto da célula"), .{ .v_align = .top, .border = .thin });
    try layout.setRowHeight(9, 40);
    try layout.setStyled(11, 2, text("Abrir o site de exemplo"), xlsx.link_style);
    try layout.setLink(11, 2, "https://example.com/");
    try layout.setStyled(12, 2, text("contato@exemplo.com.br"), xlsx.link_style);
    try layout.setLink(12, 2, "mailto:contato@exemplo.com.br");
    try layout.setStyled(14, 2, text("Texto que encolhe para caber na largura da coluna, sem quebrar a linha"), .{ .shrink = true, .border = .thin });
    try layout.setStyled(16, 2, text("Só a linha de baixo"), .{ .border_bottom = .medium });
    try layout.setStyled(18, 2, text("Sem a linha de cima"), .{ .border = .thin, .border_top = .none });
    try layout.setZoom(120);
    try layout.setPageSetup(.{ .paper = .a4, .orientation = .landscape, .margins = .{ .left = xlsx.cm(1.5), .right = xlsx.cm(1.5) } });

    // Exactly 31 characters, with accents and a dash.
    const long_name = try wb.addSheet("Relatório de ocupação — bloco A");
    try long_name.setColumnWidth(0, 60);
    try long_name.set(0, 0, text("O nome desta planilha tem 31 caracteres, o máximo permitido."));
    try long_name.set(1, 0, text("Ele deve aparecer inteiro na aba: Relatório de ocupação — bloco A"));
    return wb;
}

const options = [_][]const u8{
    "Aprovar a reforma da portaria",
    "Aprovar com ajustes no orçamento",
    "Adiar para a próxima assembleia",
    "Não aprovar",
};
const first_names = [_][]const u8{ "Fulano", "Beltrano", "Sicrano", "Ciclano", "Fulana", "Beltrana", "Sicrana", "Ciclana", "Pessoa", "Alguém", "Ninguém", "Outrem", "Morador", "Moradora", "Usuário", "Usuária" };
const last_names = [_][]const u8{ "de Tal", "Exemplo", "Teste", "Modelo", "Fictício", "Inventado", "Amostra", "Genérico", "Simulado", "Qualquer", "Demonstração" };
const roles = [_][]const u8{ "Proprietário", "Proprietário", "Proprietário", "Procurador", "Morador" };
const reasons = [_][]const u8{
    "",
    "",
    "",
    "A portaria atual não comporta as encomendas.",
    "Prefiro esperar o fechamento das contas do ano.",
    "O orçamento apresentado está acima do combinado.",
    "Concordo, desde que a obra não passe de dois meses.",
};
const vote_count = 200;

/// Which option a made-up voter picks: spread unevenly, so the result
/// sheet has something to show.
fn choice(voter: usize) usize {
    return switch ((voter * 7 + voter / 3) % 10) {
        0...4 => 0,
        5...6 => 1,
        7...8 => 2,
        else => 3,
    };
}

fn poll(gpa: std.mem.Allocator) !*xlsx.Workbook {
    const wb = try xlsx.Workbook.init(gpa);
    errdefer wb.deinit();

    var counts: [options.len]u32 = @splat(0);
    for (0..vote_count) |voter| counts[choice(voter)] += 1;

    const result = try wb.addSheet("Resultado");
    try result.setColumnWidth(0, 40);
    try result.setColumnWidth(1, 12);
    try result.setColumnWidth(2, 14);
    try result.setRow(0, 0, &.{ text("Opção"), text("Unidades"), text("Percentual") }, header);
    for (options, counts, 1..) |option, count, row| {
        try result.set(@intCast(row), 0, text(option));
        try result.set(@intCast(row), 1, .int(count));
        try result.setStyled(@intCast(row), 2, .{ .number = @as(f64, @floatFromInt(count)) / vote_count }, .{ .number_format = .percent_decimal });
    }
    const total_row = options.len + 1;
    const total: xlsx.Style = .{ .bold = true, .border = .thin };
    try result.setStyled(total_row, 0, text("Total"), total);
    try result.setStyled(total_row, 1, .{ .formula = "SUM(B2:B5)" }, total);
    try result.setStyled(total_row, 2, .{ .formula = "SUM(C2:C5)" }, .{ .bold = true, .border = .thin, .number_format = .percent_decimal });
    try result.freeze(1, 0);
    try result.setAutoFilter(.{ .first_row = 0, .first_col = 0, .last_row = options.len, .last_col = 2 });

    const votes = try wb.addSheet("Votos");
    const widths = [_]f64{ 18, 28, 16, 38, 18, 52 };
    for (widths, 0..) |width, col| try votes.setColumnWidth(@intCast(col), width);
    try votes.setRow(0, 0, &.{
        text("Unidade"),
        text("Quem votou"),
        text("Vínculo"),
        text("Opções escolhidas"),
        text("Data e hora"),
        text("Justificativa"),
    }, header);

    // Voting opens on 2026-09-21 09:00 (UTC) and votes trickle in.
    const opened_at: i64 = 1_789_981_200;
    for (0..vote_count) |voter| {
        const row: u32 = @intCast(voter + 1);
        var unit_buffer: [32]u8 = undefined;
        const unit = try std.fmt.bufPrint(&unit_buffer, "Bloco {c} - {d}", .{
            @as(u8, 'A' + @as(u8, @intCast(voter / 50))),
            (voter % 50 / 5 + 1) * 100 + voter % 5 + 1,
        });
        var name_buffer: [64]u8 = undefined;
        const name = try std.fmt.bufPrint(&name_buffer, "{s} {s}", .{
            first_names[(voter * 5 + 3) % first_names.len],
            last_names[(voter * 3 + voter / 7) % last_names.len],
        });
        try votes.set(row, 0, text(unit));
        try votes.set(row, 1, text(name));
        try votes.set(row, 2, text(roles[(voter * 3 + 1) % roles.len]));
        try votes.set(row, 3, text(options[choice(voter)]));
        try votes.setStyled(row, 4, .{ .datetime = try .fromUnix(opened_at + @as(i64, @intCast(voter)) * 2711) }, br_datetime);
        try votes.set(row, 5, text(reasons[(voter * 4 + voter / 5) % reasons.len]));
    }
    try votes.freeze(1, 1);
    try votes.setAutoFilter(.{ .first_row = 0, .first_col = 0, .last_row = vote_count, .last_col = 5 });
    // Printed on A4 lying down, with the header on every page.
    try votes.setPageSetup(.{ .paper = .a4, .orientation = .landscape });
    try votes.setPrintTitleRows(0, 0);
    return wb;
}

fn limits(gpa: std.mem.Allocator) !*xlsx.Workbook {
    const wb = try xlsx.Workbook.init(gpa);
    errdefer wb.deinit();

    // Exactly 31 characters.
    const sheet = try wb.addSheet("Nome de planilha com 31 letras!");
    try sheet.setColumnWidth(0, 60);
    try sheet.set(0, 0, text("A célula A3 tem um texto de 32.767 caracteres, o máximo de uma célula."));
    try sheet.set(1, 0, text("Ele começa com INICIO e termina com FIM. Use a fórmula =NÚM.CARACT(A3) (ou =LEN(A3)) para conferir."));
    const long_text = try gpa.alloc(u8, xlsx.max_text_len);
    defer gpa.free(long_text);
    for (long_text, 0..) |*c, i| c.* = '0' + @as(u8, @intCast(i % 10));
    @memcpy(long_text[0..6], "INICIO");
    @memcpy(long_text[long_text.len - 3 ..], "FIM");
    try sheet.set(2, 0, text(long_text));

    const corner = try wb.addSheet("Último canto");
    try corner.setColumnWidth(0, 60);
    try corner.set(0, 0, text("A última célula possível (XFD1048576) tem o texto \"canto\"."));
    try corner.set(1, 0, text("Aperte Ctrl+End para ir até ela."));
    try corner.set(xlsx.max_rows - 1, xlsx.max_cols - 1, text("canto"));
    return wb;
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    var arg_it = std.process.Args.Iterator.init(init.minimal.args);
    _ = arg_it.next(); // executable name
    const out_path = arg_it.next() orelse return error.MissingOutputDirectory;

    const cwd = std.Io.Dir.cwd();
    try cwd.createDirPath(io, out_path);
    var out_dir = try cwd.openDir(io, out_path, .{});
    defer out_dir.close(io);

    const Sample = struct { name: []const u8, build: *const fn (std.mem.Allocator) anyerror!*xlsx.Workbook };
    for ([_]Sample{
        .{ .name = "1-tudo-um-pouco.xlsx", .build = everything },
        .{ .name = "2-enquete.xlsx", .build = poll },
        .{ .name = "3-limites.xlsx", .build = limits },
    }) |sample| {
        const wb = try sample.build(gpa);
        defer wb.deinit();
        var file = try out_dir.createFile(io, sample.name, .{});
        defer file.close(io);
        var buffer: [8192]u8 = undefined;
        var file_writer = file.writer(io, &buffer);
        try wb.writeTo(&file_writer.interface);
        try file_writer.interface.flush();
    }
}
