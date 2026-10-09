//! Internal: the nodes of a parsed template (text, interpolation, if, for,
//! component, slot, helper call) and how to free them.

const std = @import("std");

pub const Prop = struct {
    name: []const u8,
    value: []const u8,
};

pub const Node = union(enum) {
    text: []const u8,
    interpolation: []const u8,
    interpolation_with_default: struct {
        expr: []const u8,
        default: []const u8,
    },
    if_node: struct {
        condition: []const u8,
        then_body: []Node,
        else_body: ?[]Node,
    },
    for_node: struct {
        iterable: []const u8,
        capture: []const u8,
        body: []Node,
    },
    component: struct {
        name: []const u8,
        props: []Prop,
        self_closing: bool,
        slot_content: ?[]const u8,
    },
    slot: void,
    // { name("literal", "literal") } — dispatched at render time to a
    // function registered in the app's `template_helpers` module. Args are
    // string literals only (no context-variable resolution) by design.
    call: struct {
        name: []const u8,
        args: [][]const u8,
    },
};

pub fn freeNode(node: Node, alc: std.mem.Allocator) void {
    switch (node) {
        .text => |s| alc.free(s),
        .interpolation => |s| alc.free(s),
        .interpolation_with_default => |iwd| {
            alc.free(iwd.expr);
            alc.free(iwd.default);
        },
        .if_node => |ifn| {
            alc.free(ifn.condition);
            for (ifn.then_body) |n| freeNode(n, alc);
            alc.free(ifn.then_body);
            if (ifn.else_body) |eb| {
                for (eb) |n| freeNode(n, alc);
                alc.free(eb);
            }
        },
        .for_node => |fnn| {
            alc.free(fnn.iterable);
            alc.free(fnn.capture);
            for (fnn.body) |n| freeNode(n, alc);
            alc.free(fnn.body);
        },
        .component => |comp| {
            alc.free(comp.name);
            for (comp.props) |prop| {
                alc.free(prop.name);
                alc.free(prop.value);
            }
            alc.free(comp.props);
            if (comp.slot_content) |sc| alc.free(sc);
        },
        .slot => {},
        .call => |c| {
            alc.free(c.name);
            for (c.args) |a| alc.free(a);
            alc.free(c.args);
        },
    }
}
