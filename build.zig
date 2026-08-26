const std = @import("std");
const AutoConfigHeaderStep = @import("autoconfigheader").AutoConfigHeaderStep;

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const linkage = b.option(std.builtin.LinkMode, "linkage", "Linkage type for the library") orelse .static;
    const enable_egl = b.option(bool, "egl", "Controls EGL support") orelse true;
    const enable_x11 = b.option(bool, "x11", "Controls X11 support") orelse true;
    const enable_glx = b.option(bool, "glx", "Controls GLX support") orelse true;
    const enable_gles1 = b.option(bool, "gles1", "Controls support for OpenGL ES 1.x API") orelse true;
    const enable_gles2 = b.option(bool, "gles2", "Controls support for OpenGL ES 2.x API") orelse true;
    const entrypoint_patching = b.option(bool, "entrypoint-patching", "Controls OpenGL entrypoint patching optimization") orelse true;
    const enable_asm = b.option(bool, "asm", "Controls assembly usage on supported platforms") orelse true;
    const enable_tls = b.option(bool, "tls", "Controls TLS usage on supported platforms") orelse true;
    const gldispatch_page_size = b.option(bool, "gldispatch_page_size", "Page size to align static dispatch stubs.");

    const config_h = AutoConfigHeaderStep.create(b, target, .{
        .style = .blank,
        .include_path = "config.h",
    });
    if (enable_x11) {
        config_h.config_header.addValues(.{
            .ENABLE_X11 = true,
            .ENABLE_EGL_X11 = true,
        });
    }
    if (enable_egl) {
        config_h.config_header.addValues(.{
            .ENABLE_EGL = true,
            .ENABLE_EGL_HEADERS = true,
        });
    }
    if (enable_glx) {
        config_h.config_header.addValues(.{
            .ENABLE_GLX = true,
            .ENABLE_GLX_HEADERS = true,
        });
    }
    if (enable_gles1) {
        config_h.config_header.addValues(.{
            .ENABLE_GLES1_HEADERS = true,
            .ENABLE_GLES1 = true,
        });
    }
    if (enable_gles2) {
        config_h.config_header.addValues(.{
            .ENABLE_GLES2_HEADERS = true,
            .ENABLE_GLES2 = true,
        });
    }
    if (entrypoint_patching) {
        config_h.config_header.addValues(.{ .GLDISPATCH_ENABLE_PATCHING = true });
    }
    if (enable_asm) {
        switch (target.result.cpu.arch) {
            .x86 => config_h.config_header.addValues(.{ .USE_X86_ASM = true }),
            .x86_64 => config_h.config_header.addValues(.{ .USE_X86_64_ASM = true }),
            .aarch64, .aarch64_be => config_h.config_header.addValues(.{ .USE_AARCH64_ASM = true }),
            .powerpc64, .powerpc64le => config_h.config_header.addValues(.{ .USE_PPC64_ASM = true }),
            .loongarch64 => config_h.config_header.addValues(.{ .USE_LOONGARCH64_ASM = true }),
            else => {}, // target is not supported
        }
    }
    if (enable_tls) {
        // TODO: add tls support check
        config_h.config_header.addValues(.{
            .GLDISPATCH_USE_TLS = true,
        });
        // config_h.addHaveFunction("GLDISPATCH_USE_TLS", "__thread int foo;", &.{});
    }
    config_h.config_header.addValues(.{ .USE_ATTRIBUTE_CONSTRUCTOR = true });
    config_h.addHaveFunction("HAVE_PTHREAD_RWLOCK_T", "pthread_rwlock_init((pthread_rwlock_t *)0, NULL)", &.{"pthread.h"});
    config_h.addHaveFunction("HAVE_SYNC_INTRINSICS", "__sync_add_and_fetch((int volatile *)0, 1); __sync_lock_test_and_set((int volatile *)0, 1); __sync_val_compare_and_swap((int volatile *)0, 1, 2)", &.{});
    config_h.addHaveFunction("HAVE_MINCORE", "&mincore", &.{"sys/mman.h"});
    config_h.addHaveFunction("HAVE_RTLD_NOLOAD", "RTLD_NOLOAD", &.{"dlfcn.h"});
    config_h.addHaveFunction("HAVE_DIRENT_DTYPE", "((struct dirent *)0)->d_type", &.{"dirent.h"});
    config_h.config_header.addValues(.{
        .GLDISPATCH_PAGE_SIZE = gldispatch_page_size,
        .EGL_NO_X11 = true,
        .MAPI_ABI_HEADER = "glapi_mapi.h",
    });

    const flags = .{"--includeconfig.h"};

    const glvnd_dep = b.dependency("glvnd", .{});

    const mod_glapi = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .pic = if (linkage == .dynamic) true else null,
    });
    mod_glapi.addConfigHeader(config_h.config_header);

    mod_glapi.addIncludePath(b.path("include"));
    mod_glapi.addIncludePath(glvnd_dep.path("include"));
    mod_glapi.addIncludePath(glvnd_dep.path("src/GLdispatch/vnd-glapi"));
    mod_glapi.addIncludePath(glvnd_dep.path("src/util"));
    const gldispatch_entry_type: enum { tls, tsd, pure_c } = entry_type: switch (target.result.cpu.arch) {
        .x86, .x86_64, .powerpc64, .arm, .aarch64, .loongarch64 => {
            if (enable_tls and (target.result.isGnuLibC() or target.result.isMinGW() or target.result.isFreeBSDLibC())) {
                break :entry_type .tls;
            } else {
                break :entry_type .tsd;
            }
        },
        else => {
            break :entry_type .pure_c;
        },
    };
    const gldispatch_entry_files = switch (target.result.cpu.arch) {
        .x86 => switch (gldispatch_entry_type) {
            .tls => .{ "entry_x86_tls.c", "entry_simple_asm.c", "entry_common.c" },
            .tsd => .{ "entry_x86_tsd.c", "entry_simple_asm.c", "entry_common.c" },
            else => @panic("unexpected value"),
        },
        .x86_64 => switch (gldispatch_entry_type) {
            .tls => .{ "entry_x86_64_tls.c", "entry_simple_asm.c", "entry_common.c" },
            .tsd => .{ "entry_x86_64_tsd.c", "entry_simple_asm.c", "entry_common.c" },
            else => @panic("unexpected value"),
        },
        .arm => switch (gldispatch_entry_type) {
            .tsd => .{ "entry_armv7_tsd.c", "", "entry_common.c" },
            else => @panic("unexpected value"),
        },
        .aarch64 => switch (gldispatch_entry_type) {
            .tsd => .{ "entry_aarch64_tsd.c", "entry_simple_asm", "entry_common.c" },
            else => @panic("unexpected value"),
        },
        .powerpc64 => switch (gldispatch_entry_type) {
            .tls => .{ "entry_ppc64_tls.c", "entry_simple_asm.c", "entry_common.c" },
            .tsd => .{ "entry_ppc64_tsd.c", "entry_simple_asm.c", "entry_common.c" },
            else => @panic("unexpected value"),
        },
        .loongarch64 => switch (gldispatch_entry_type) {
            .tsd => .{ "entry_loongarch64_tsd.c", "entry_simple_asm", "entry_common.c" },
            else => @panic("unexpected value"),
        },
        else => .{ "entry_pure_c.c", "", "" },
    };
    mod_glapi.addCSourceFiles(.{
        .root = glvnd_dep.path("src/GLdispatch/vnd-glapi"),
        .files = &gldispatch_entry_files,
        .flags = &flags,
    });
    const current_files = if (enable_tls) .{"u_current_tls.c"} else .{"u_current_tsd.c"};
    mod_glapi.addCSourceFiles(.{
        .root = glvnd_dep.path("src/GLdispatch/vnd-glapi"),
        .files = &current_files,
        .flags = &flags,
    });
    mod_glapi.addCSourceFiles(.{
        .root = glvnd_dep.path("src/GLdispatch"),
        .files = &gldispatch_sources,
        .flags = &flags,
    });

    const lib_glapi = b.addLibrary(.{
        .name = "glapi",
        .root_module = mod_glapi,
    });
    b.installArtifact(lib_glapi);

    const mod_glvnd = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .pic = if (linkage == .dynamic) true else null,
    });
    mod_glvnd.linkLibrary(lib_glapi);
    mod_glvnd.addConfigHeader(config_h.config_header);

    mod_glvnd.addIncludePath(glvnd_dep.path("include"));
    mod_glvnd.addIncludePath(glvnd_dep.path("src/util"));
    mod_glvnd.addIncludePath(glvnd_dep.path("src/util/uthash/src"));
    mod_glvnd.addIncludePath(glvnd_dep.path("src/GLdispatch/vnd-glapi"));

    mod_glvnd.addCSourceFiles(.{
        .root = glvnd_dep.path("src/util"),
        .files = &util_sources,
        .flags = &flags,
    });

    const lib_glvnd = b.addLibrary(.{
        .name = "glvnd",
        .root_module = mod_glvnd,
        .linkage = linkage,
    });
    lib_glvnd.installHeadersDirectory(glvnd_dep.path("include"), ".", .{});
    b.installArtifact(lib_glvnd);

    const gen_step = b.step("gen", "generate source code");

    const glapi_mapi_tmp_run = b.addSystemCommand(&.{"python3"});
    glapi_mapi_tmp_run.addFileArg(glvnd_dep.path("src/generate/gen_gldispatch_mapi.py"));
    glapi_mapi_tmp_run.addArg("gldispatch");
    glapi_mapi_tmp_run.addFileArg(glvnd_dep.path("src/generate/xml/gl.xml"));
    glapi_mapi_tmp_run.addFileArg(glvnd_dep.path("src/generate/xml/gl_other.xml"));
    const glapi_mapi_tmp = glapi_mapi_tmp_run.captureStdOut(.{ .basename = "glapi_mapi_tmp.h" });

    const usf = b.addUpdateSourceFiles();
    usf.addCopyFileToSource(glapi_mapi_tmp, "include/glapi_mapi.h");
    gen_step.dependOn(&usf.step);
}

const util_sources = .{
    "app_error_check.c",
    "cJSON.c",
    "glvnd_pthread.c",
    "trace.c",
    "utils_misc.c",
    "winsys_dispatch.c",
};

const gldispatch_sources = .{
    "GLdispatch.c",
    "vnd-glapi/mapi_glapi.c",
    "vnd-glapi/stub.c",
    "vnd-glapi/table.c",
};
