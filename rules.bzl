"""Build rules for Common Lisp.

The three rules defined here are:
  lisp_library - The basic unit of compilation
  lisp_binary - Outputs an executable binary
  lisp_test - Outputs a binary that is run with the test command
"""

load(
    "//:provider.bzl",
    "LispInfo",
    "collect_lisp_info",
    "extend_lisp_info",
)
load("@rules_cc//cc:find_cc_toolchain.bzl", "find_cc_toolchain")
load("@bazel_skylib//rules:common_settings.bzl", "BuildSettingInfo")

_BAZEL_LISP_IMAGE = "//:image"
_BAZEL_LISP_IMAGE_MAIN = "bazel.main:main"
_BAZEL_LISP_IMAGE_ENV = {"LISP_MAIN": _BAZEL_LISP_IMAGE_MAIN}
_ELFINATE = "@local_sbcl//:elfinate"
_DEFAULT_MALLOC = "@bazel_tools//tools/cpp:malloc"
_DEFAULT_LIBSBCL = "@local_sbcl//:c-support"

_COMPILATION_ORDERS = ["multipass", "serial", "parallel"]
_LISP_LIBRARY_ATTRS = {
    "srcs": attr.label_list(
        allow_files = [".lisp", ".lsp"],
        doc = ("Common Lisp (`.lisp` or `.lsp`) source files. If there are " +
               "multiple files in `srcs`, which other files in `srcs` are " +
               "loaded before each file is compiled depends on the `order` " +
               "attr."),
    ),
    "deps": attr.label_list(
        providers = [LispInfo],
        doc = ("Common Lisp dependencies (generally [`lisp_library`]" +
               "(#lisp-library), but you can put [`lisp_binary`]" +
               "(#lisp-binary) in deps for testing)."),
    ),
    "cdeps": attr.label_list(
        providers = [CcInfo],
        doc = ("C++ dependencies (generally [`cc_library`]" +
               "(https://docs.bazel.build/versions/master/be/c-cpp.html" +
               "#cc_library))"),
    ),
    "order": attr.string(
        default = "serial",
        values = _COMPILATION_ORDERS,
        doc = (
            "Compilation order, one of:\n" +
            "\n" +
            '`"serial"` (default) - Each source is compiled in an image ' +
            "with previous sources loaded. (Note that in this " +
            "configuration you should put a comment at the top of the " +
            "list of srcs if there is more than one, so that formatters " +
            "like Buildozer do not change the order.)\n" +
            "\n" +
            '`"multipass"` - Each source is compiled in an image with all ' +
            "sources loaded.\n" +
            "\n" +
            '`"parallel"` - Each source is compiled independently.'
        ),
    ),
    "data": attr.label_list(
        allow_files = True,
        doc = ("Data available to this target's consumers in the runfiles " +
               "directory at runtime."),
    ),
    "compile_data": attr.label_list(
        allow_files = True,
        doc = ("Similar to `data`, except it is also made available in the " +
               "runfiles of the build image of this target's consumers at " +
               "compile time."),
    ),
    "add_features": attr.string_list(
        doc = ("Names of symbols (by default in the keyword package) to be " +
               "added to `\\*features\\*` of this library and its consumers, at " +
               "compile time and in the resulting binary. Note that this " +
               "differs from the [`features`](https://docs.bazel.build/" +
               "versions/master/be/common-definitions.html#common.features) " +
               "attribute common to all build rules which controls " +
               "[toolchain](https://docs.bazel.build/versions/master/" +
               "toolchains.html) features)"),
    ),
    "nowarn": attr.string_list(
        doc = "Suppressed Lisp warning types or warning handlers.",
    ),
    "image": attr.label(
        allow_single_file = True,
        executable = True,
        cfg = "target",
        default = Label(_BAZEL_LISP_IMAGE),
        # TODO(sfreilich): More about how to extend the image could be
        # documented and enforced.
        doc = "Lisp binary used as Bazel compilation image.",
    ),
    "verbose": attr.int(
        default = 0,
        doc = ("Enable verbose debugging output when analyzing and " +
               "compiling this target (`0` = none (default), `3` = max)."),
    ),
    "instrument_coverage": attr.int(
        values = [-1, 0, 1],
        default = -1,
        doc = (
            "Force coverage instrumentation. Possible values:\n" +
            "\n" +
            "`0`: Never instrument this target. Should be used if the" +
            "target compiles generated source files or does not compile" +
            "with coverage instrumentation.\n" +
            "\n" +
            "`1`: Always instrument this target. Generally should not be " +
            "used outside of tests for the coverage implementation.\n" +
            "\n" +
            "`-1` (default): If coverage data collection is enabled, " +
            "instrument this target per [`--instrumentation_filter]" +
            "(https://docs.bazel.build/versions/master/" +
            "command-line-reference.html#flag--instrumentation_filter).`"
        ),
    ),
    "_additional_dynamic_load_outputs": attr.label(
        default = Label(
            "//:additional_dynamic_load_outputs",
        ),
        providers = [BuildSettingInfo],
    ),
    # Do not add references, temporary attribute for find_cc_toolchain.
    "_cc_toolchain": attr.label(
        default = Label("@bazel_tools//tools/cpp:current_cc_toolchain"),
    ),
}

_LISP_BINARY_ATTRS = dict(_LISP_LIBRARY_ATTRS)
_LISP_BINARY_ATTRS.update({
    "main": attr.string(
        default = "main",
        doc = ("Name of function (by default in the `cl-user` package) or " +
               "snippet of Lisp code to run when starting the binary. " +
               '`"nil"` to start the default REPL. Can be overridden at ' +
               "runtime with the `LISP_MAIN` environment variable."),
    ),
    "malloc": attr.label(
        default = _DEFAULT_MALLOC,
        providers = [CcInfo],
        doc = ("Target providing a custom malloc implementation. Same as " +
               "[`cc_binary.malloc`](https://docs.bazel.build/versions/" +
               "master/be/c-cpp.html#cc_binary.malloc). Note that these " +
               "rules do not respect [`--custom_malloc`]" +
               "(https://docs.bazel.build/versions/master/" +
               "command-line-reference.html#flag--custom_malloc)."),
    ),
    "stamp": attr.int(
        values = [-1, 0, 1],
        default = -1,
        doc = ("Same as [`cc_binary.stamp`](https://docs.bazel.build/" +
               "versions/master/be/c-cpp.html#cc_binary.stamp)."),
    ),
    "allow_save_lisp": attr.bool(
        default = False,
        doc = ("Whether to preserve the ability to run `save-lisp-and-die` " +
               "instead of altering the binary format to be more compatible " +
               "with C++ debugging tools (which, for example, allows you to " +
               "get combined stacktraces of C/C++ and Lisp code). Must be " +
               "`True` for targets used as a compilation image."),
    ),
    "precompile_generics": attr.bool(
        default = True,
        doc = "If `False`, skip precompiling generic functions.",
    ),
    "save_runtime_options": attr.bool(
        default = True,
        doc = ("If `False`, process SBCL runtime options at the command-line" +
               "on binary startup."),
    ),
    "runtime": attr.label(
        default = Label(_DEFAULT_LIBSBCL),
        providers = [CcInfo],
        doc = ("SBCL C++ dependencies. Consumers should generally omit this " +
               "attr and use the default value."),
    ),
    "_elfinate": attr.label(
        default = Label("@local_sbcl//:elfinate"),
        executable = True,
        allow_single_file = True,
        cfg = "target",
    ),
    "_custom_malloc": attr.label(
        default = configuration_field(
            fragment = "cpp",
            name = "custom_malloc",
        ),
        providers = [CcInfo],
    ),
})

_LISP_TEST_ATTRS = dict(_LISP_BINARY_ATTRS)
_LISP_TEST_ATTRS.update({
    "stamp": attr.int(
        values = [-1, 0, 1],
        default = 0,
        doc = ("Same as [`cc_test.stamp`](https://docs.bazel.build/" +
               "versions/master/be/c-cpp.html#cc_test.stamp). Build version " +
               "stamping is disabled by default."),
    ),
})

def _paths(files, sep = " "):
    """Return the full file paths for all the 'files'.

    Args:
     files: a list of build file objects.
     sep: String to join on, by default a space.

    Returns:
      Joined string of file paths.
    """
    return sep.join([f.path for f in files])

def _spec(spec, files):
    """Return the compilation/linking specification as parsed by bazel driver.

    The specification will have the following form:
      (:<spec> "<path>" .... "<path>")
    for each spec and path of the files.

    Args:
      spec: the specification name corresponding to the command line argument.
      files: a list of build file objects to be included in the specification.

    Returns:
      A list of parenthesized paths prefixed with specs name as keyword.
    """
    return '(:{}\n "{}")\n'.format(spec, _paths(files, sep = '"\n "'))

def _concat_files(ctx, inputs, output):
    """Concatenates several FASLs into a combined FASL.

    Args:
      ctx: Rule context
      inputs: List of files to concatenate.
      output: File output for the concatenated contents.
    """
    if not inputs:
        cmd = "touch " + output.path
        msg = "Linking {} (as empty FASL)".format(output.short_path)
    elif len(inputs) == 1:
        cmd = "mv {} {}".format(inputs[0].path, output.path)
        msg = "Linking {} (from 1 source)".format(output.short_path)
    else:
        cmd = "cat {} > {}".format(_paths(inputs), output.path)
        msg = "Linking {} (from {} sources)".format(output.short_path, len(inputs))

    ctx.actions.run_shell(
        inputs = inputs,
        outputs = [output],
        progress_message = msg,
        mnemonic = "LispConcatFASLs",
        command = cmd,
    )

def _build_flags(ctx, add_features, verbose_level, instrument_coverage):
    """Returns Args for flags for all Lisp build actions.

    Args:
     ctx: The rule context.
     add_features: Depset of transitive Lisp feature strings provided by this
         target and its dependencies.
     verbose_level: int indicating level of debugging output. If positive, a
         --verbose flags is added.
     instrument_coverage: Controls coverage instrumentation, with the following
         values:
         -1 (default) - Instruments if coverage is enabled for this target.
         0 - Instruments never.
         1 - Instruments always (for testing purposes).

    Returns:
        Args object to be passed to Lisp build actions.
    """
    cc_toolchain = find_cc_toolchain(ctx)

    # Needs to match logic for the :msan config_setting target. Unfortunately,
    # config_setting rules don't yet have a Starlark API. Note that this is not
    # equivalent to looking at ctx.var.get("msan_config"), we want to know if
    # msan is used in this specific configuration, not if it's an msan build in
    # general. (It might be better to look at whether msan is enabled in
    # features with cc_common.configure_features (_cc_configure_features) and
    # cc_common.is_enabled, but the important thing is that the behavior is
    # consistent between this target and the targets in its image and runtime
    # attrs.)
    if cc_toolchain.compiler == "msan":
        add_features = depset(["msan"], transitive = [add_features])
    flags = ctx.actions.args()
    flags.add(
        "--compilation-mode",
        ctx.var.get("LISP_COMPILATION_MODE", ctx.var["COMPILATION_MODE"]),
    )
    flags.add("--bindir", ctx.bin_dir.path)
    flags.add_joined("--features", add_features, join_with = " ")

    if (instrument_coverage > 0 or
        (instrument_coverage < 0 and ctx.coverage_instrumented())):
        flags.add("--coverage")

    if verbose_level > 0:
        flags.add("--verbose", str(verbose_level))

    if int(ctx.var.get("LISP_BUILD_FORCE", "0")) > 0:
        flags.add("--force")

    return flags

def _list_excluding_depset(items, exclude):
    exclude_set = {item: True for item in exclude.to_list()}
    return [item for item in items if item not in exclude_set]

def lisp_compile_srcs(
        ctx,
        srcs,
        deps,
        cdeps,
        image,
        add_features,
        nowarn,
        order,
        compile_data,
        verbose_level,
        instrument_coverage = -1,
        indexer_metadata = []):
    """Generate LispCompile actions, return LispInfo and FASL output.

    This is the core functionality shared by the Lisp build rules.

    Args:
      ctx: The rule context.
      srcs: List of src Files.
      deps: List of immediate Lisp dependency Targets.
      cdeps: List of immediate C++ dependency Targets.
      image: Build image Target used to compile the sources.
      add_features: List of Lisp feature strings added by this target.
      nowarn: List of suppressed warning type strings.
      order: Order in which to load sources, either "serial", "parallel", or
          "multipass".
      compile_data: depset of additional data Files used for compilation.
      verbose_level: int indicating level of debugging output.
      instrument_coverage: Controls coverage instrumentation, with the following values:
         -1 (default) - Instruments if coverage is enabled for this target.
         0 - Instruments never.
         1 - Instruments always (for testing purposes).
      indexer_metadata: Extra metadata files to be passed to the --deps
         flag of LispCompile when the indexer is run. Ignored by the build
         image itself.

    Returns:
      struct with fields:
          - lisp_info: LispInfo for the target
          - output_fasl: Combined FASL for this target (which is also included in
              lisp_info.fasls if there are srcs)
          - build_flags: Args to pass to all LispCompile and LispCore actions
    """
    if not order in _COMPILATION_ORDERS:
        fail("order {} must be one of {}".format(order, _COMPILATION_ORDERS))

    name = ctx.label.name
    verbosep = verbose_level > 0
    indexer_build = (ctx.var.get("GROK_ELLIPSIS_BUILD", "0") == "1")

    lisp_info = collect_lisp_info(
        deps = deps,
        cdeps = cdeps,
        build_image = image,
        features = add_features,
        compile_data = compile_data,
    )
    output_fasl = ctx.actions.declare_file(name + ".fasl")
    build_flags = _build_flags(
        ctx = ctx,
        add_features = lisp_info.features,
        verbose_level = verbose_level,
        instrument_coverage = instrument_coverage,
    )

    if not srcs:
        _concat_files(ctx, [], output_fasl)
        return struct(
            lisp_info = lisp_info,
            output_fasl = output_fasl,
            build_flags = build_flags,
        )

    multipass = (order == "multipass")
    serial = (order == "serial")

    build_image = image[DefaultInfo].files_to_run
    compile_image = build_image

    # Lisp source files for all the transitive dependencies not already in the
    # image, loaded before compilation, passed to --deps.
    deps_srcs = lisp_info.srcs.to_list()
    if LispInfo in image:
        deps_srcs = _list_excluding_depset(deps_srcs, image[LispInfo].srcs)
    if indexer_build:
        deps_srcs.extend(indexer_metadata)

    # Sources for this target loaded before compilation (after deps), passed to
    # --load. What this contains depends on the compilation order:
    # multipass: Contains everything
    # parallel: Contains nothing
    # serial: Contains previous entries in srcs (accumulated below)
    load_srcs = srcs if multipass else []

    # Arbitrary heuristic to reduce load on the build system by bundling
    # FASL and source files load into one compile-image binary.
    compile_flags = ctx.actions.args()

    if multipass:
        nowarn = nowarn + ["redefined-method", "redefined-function"]

    # buildozer: disable=print
    if verbosep:
        print("Target: " + name)
        print("Build Img: " + build_image.executable.short_path)
        print("Compile Img: " + compile_image.executable.short_path)

    fasls = []
    warnings = []
    hashes = []
    for src in srcs:
        stem = src.short_path[:-len(src.extension) - 1]
        fasls.append(ctx.actions.declare_file(stem + "~.fasl"))
        hashes.append(ctx.actions.declare_file(stem + "~.hash"))
        warnings.append(ctx.actions.declare_file(stem + "~.warnings"))
        outs = [fasls[-1], hashes[-1], warnings[-1]]
        file_flags = ctx.actions.args()
        file_flags.add_joined("--outs", outs, join_with = " ")
        file_flags.add("--srcs", src)
        file_flags.add_joined("--deps", deps_srcs, join_with = " ")
        file_flags.add_joined("--load", load_srcs, join_with = " ")
        file_flags.add_joined("--nowarn", nowarn, join_with = " ")

        ctx.actions.run(
            outputs = outs,
            inputs = depset(
                [src] + deps_srcs + load_srcs,
                transitive = [lisp_info.compile_data],
            ),
            progress_message = "Compiling " + src.short_path,
            mnemonic = "LispCompile",
            env = _BAZEL_LISP_IMAGE_ENV,
            arguments = ["compile", build_flags, compile_flags, file_flags],
            executable = compile_image,
        )
        if serial:
            load_srcs.append(src)

    # Need to concatenate the FASL files into name.fasl.
    _concat_files(ctx, fasls, output_fasl)
    if indexer_build:
        srcs = indexer_metadata + srcs
    lisp_info = extend_lisp_info(
        lisp_info,
        srcs = srcs,
        fasls = [output_fasl] if srcs else [],
        hashes = hashes,
        warnings = warnings,
    )
    return struct(
        lisp_info = lisp_info,
        output_fasl = output_fasl,
        build_flags = build_flags,
    )

def _cc_configure_features(ctx, cc_toolchain):
    return cc_common.configure_features(
        ctx = ctx,
        cc_toolchain = cc_toolchain,
        requested_features = ctx.features,
        unsupported_features = ctx.disabled_features,
    )

# DEPS file is used to list all the Lisp sources for a target.
# It is a quick hack to make (bazel:load ...) work.
def _lisp_deps_manifest(ctx, lisp_info):
    """Creates a file that lists all Lisp files needed by the target in order."""
    out = ctx.actions.declare_file(ctx.label.name + ".deps")
    content = ctx.actions.args()
    content.set_param_file_format("multiline")
    content.add_joined(
        lisp_info.features,
        join_with = "\n",
        format_each = "feature: %s",
    )
    content.add_joined(
        lisp_info.srcs,
        join_with = "\n",
        format_each = "src: %s",
    )
    ctx.actions.write(
        output = out,
        content = content,
    )
    return out

def _lisp_dynamic_library(ctx, lisp_info):
    cc_toolchain = find_cc_toolchain(ctx)
    feature_configuration = _cc_configure_features(ctx, cc_toolchain)
    linking_outputs = cc_common.link(
        name = ctx.label.name,
        actions = ctx.actions,
        feature_configuration = feature_configuration,
        cc_toolchain = cc_toolchain,
        linking_contexts = [lisp_info.cc_info.linking_context],
        output_type = "dynamic_library",
    )
    return linking_outputs.library_to_link.dynamic_library

def _lisp_output_group_info(ctx, lisp_info, fasl):
    outputs = {"fasl": [fasl]}

    # Additional outputs for dynamic loading. These should only be used when
    # explicitly requested, so condition the generation of the extra actions
    # on a flag. (It might be better to just condition this on --output_groups,
    # but that's not readable from Starlark.)
    generate_dynamic_load_outputs = (
        ctx.attr._additional_dynamic_load_outputs[BuildSettingInfo].value
    )
    if generate_dynamic_load_outputs:
        outputs["deps_manifest"] = [_lisp_deps_manifest(ctx, lisp_info)]
        outputs["dynamic_library"] = [_lisp_dynamic_library(ctx, lisp_info)]

    return OutputGroupInfo(**outputs)

def _lisp_instrumented_files_info(ctx):
    return coverage_common.instrumented_files_info(
        ctx,
        source_attributes = ["srcs"],
        dependency_attributes = ["deps", "cdeps", "image"],
    )

def _lisp_runfiles(ctx):
    runfiles_deps = (ctx.attr.deps + ctx.attr.cdeps + [ctx.attr.image] +
                     ctx.attr.data + ctx.attr.compile_data)
    runfiles = ctx.runfiles(files = ctx.files.data + ctx.files.compile_data)
    for dep in runfiles_deps:
        runfiles = runfiles.merge(dep[DefaultInfo].default_runfiles)
    return runfiles

def _lisp_providers(ctx, lisp_info, fasl, executable = None):
    return [
        DefaultInfo(
            runfiles = _lisp_runfiles(ctx),
            files = depset([executable or fasl]),
            executable = executable,
        ),
        lisp_info,
        _lisp_output_group_info(ctx, lisp_info, fasl),
        _lisp_instrumented_files_info(ctx),
    ]

################################################################################
# Lisp Binary and Lisp Test
################################################################################

def _lisp_binary_impl(ctx):
    """Implementation for lisp_binary and lisp_test rules."""
    name = ctx.label.name
    core = ctx.actions.declare_file(name + ".core")
    verbose_level = max(
        ctx.attr.verbose,
        int(ctx.var.get("VERBOSE_LISP_BUILD", "0")),
    )
    verbosep = verbose_level > 0

    # buildozer: disable=print
    if verbosep:
        print("~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~")
        print("Core: %s" % core)

    compile = lisp_compile_srcs(
        ctx = ctx,
        srcs = ctx.files.srcs,
        deps = ctx.attr.deps,
        cdeps = ctx.attr.cdeps,
        image = ctx.attr.image,
        add_features = ctx.attr.add_features,
        nowarn = ctx.attr.nowarn,
        order = ctx.attr.order,
        compile_data = ctx.files.compile_data,
        verbose_level = verbose_level,
        instrument_coverage = ctx.attr.instrument_coverage,
    )

    # TODO(czak): Add --hashes, and --warnings flags to bazl.main.
    lisp_info = compile.lisp_info

    fasls = lisp_info.fasls.to_list()
    hashes = lisp_info.hashes.to_list()
    warnings = lisp_info.warnings.to_list()

    if LispInfo in ctx.attr.image:
        # The image already includes some deps.
        included = ctx.attr.image[LispInfo]
        fasls = _list_excluding_depset(fasls, included.fasls)
        hashes = _list_excluding_depset(hashes, included.hashes)
        warnings = _list_excluding_depset(warnings, included.warnings)

    build_image = ctx.file.image

    # buildozer: disable=print
    if verbosep:
        print("Build image: %s" % build_image.short_path)

    specs = ctx.actions.declare_file(name + ".specs")
    ctx.actions.write(
        output = specs,
        content = (
            "".join([
                _spec("deps", fasls),
                _spec("warnings", warnings),
                _spec("hashes", hashes),
            ])
        ),
    )

    inputs = [specs]
    inputs.extend(fasls)
    inputs.extend(hashes)
    inputs.extend(warnings)
    inputs = depset(inputs, transitive = [lisp_info.compile_data])

    core_flags = ctx.actions.args()
    core_flags.add("--specs", specs)
    core_flags.add("--outs", core)
    core_flags.add("--main", ctx.attr.main)
    core_flags.add_joined("--nowarn", ctx.attr.nowarn, join_with = " ")
    if ctx.attr.precompile_generics:
        core_flags.add("--precompile-generics")
    if ctx.attr.save_runtime_options:
        core_flags.add("--save-runtime-options")
    ctx.actions.run(
        outputs = [core],
        inputs = inputs,
        progress_message = "Building Lisp core " + core.short_path,
        mnemonic = "LispCore",
        env = _BAZEL_LISP_IMAGE_ENV,
        arguments = ["core", compile.build_flags, core_flags],
        executable = build_image,
    )

    cc_toolchain = find_cc_toolchain(ctx)
    feature_configuration = _cc_configure_features(ctx, cc_toolchain)

    # The support in ELFinator exists for -pie code, and a non-elfinated SBCL binaries
    # are always position-independent; however, extreme inefficiency is imparted to ELF
    # binaries that are position-independent. Lisp pointers are all absolute, and a
    # typical Lisp heap might contain 3 to 5 million pointers to functions, therefore
    # require that many relocations on each invocation to adjust to wherever the system
    # moved the text segment. C on the other hand uses function pointers sparingly.
    # I don't have "typical" numbers of pointers, and it can't be inferred from a binary,
    # but it's nothing like having 40,000 closures over #<FUNCTION ALWAYS-BOUND {xxxxxx}>
    # (which is the SLOT-BOUNDP method "fast method function" for every defstruct slot)
    # and another 40,000 over CALL-NEXT-METHOD and so on and so on.
    linkopts = ["-Wl,-no-pie"]

    # Transform the .core file into a -core.o file, so that can be linked in
    # with the C++ dependencies.
    core_object_file = ctx.actions.declare_file(name + "-core.o")
    link_additional_inputs = []
    compilation_outputs = [
        cc_common.create_compilation_outputs(
            # This file contains the SBCL core, essentially as '.data' in the
            # object file, so it can be linked as PIC or not. For the other
            # dependencies, we still want the link action to choose normally
            # between PIC and non-PIC outputs.
            objects = depset([core_object_file]),
            pic_objects = depset([core_object_file]),
        ),
    ]
    if ctx.attr.allow_save_lisp:
        # If we want to allow the binary to be used as a compilation image, the
        # Lisp image has to stay in a form save-lisp-and-die understands. In
        # this case, copy the entire native SBCL core into a binary blob in a
        # normal '.o' file.
        linker_script_file = ctx.actions.declare_file(name + "-syms.lds")
        link_additional_inputs.append(linker_script_file)
        elfinate_outs = [core_object_file, linker_script_file]
        elfinate_cmd = (
            "{elfinate} copy {core} {core_obj} && nm -p {core_obj} | " +
            "awk '" +
            '{{print $2";"}}BEGIN{{print "{{"}}END{{print "}};"}}' +
            "' >{linker_script}"
        ).format(
            elfinate = ctx.executable._elfinate.path,
            core = core.path,
            core_obj = core_object_file.path,
            linker_script = linker_script_file.path,
        )
        linkopts.append(
            "-Wl,--dynamic-list={}".format(linker_script_file.path),
        )
    else:
        # Otherwise, produce a '.s' file holding only compiled Lisp code and a
        # '-core.o' containing the balance of the original Lisp spaces.
        assembly_file = ctx.actions.declare_file(name + ".s")
        elfinate_outs = [assembly_file, core_object_file]
        elfinate_cmd = "{elfinate} split {core} {asm}".format(
            elfinate = ctx.executable._elfinate.path,
            core = core.path,
            asm = assembly_file.path,
        )

        # The .s file will get re-assembled before it's linked into the binary.
        # Note that this cc_common.compile action is declared before the
        # action below which runs elfinate to create this input. The elfinate
        # action still ends up first when the graph of actions is computed.
        compilation_context, asm_compilation_output = cc_common.compile(
            name = name,
            actions = ctx.actions,
            feature_configuration = feature_configuration,
            cc_toolchain = cc_toolchain,
            srcs = [assembly_file],
        )
        compilation_outputs.append(asm_compilation_output)

    ctx.actions.run_shell(
        outputs = elfinate_outs,
        tools = [ctx.executable._elfinate],
        inputs = [core],
        command = elfinate_cmd,
        progress_message = "Elfinating Lisp core " + core.short_path,
        mnemonic = "LispElfinate",
    )

    # The rule's malloc attribute can be overridden by the --custom_malloc flag.
    malloc = ctx.attr._custom_malloc or ctx.attr.malloc
    linking_outputs = cc_common.link(
        name = name,
        actions = ctx.actions,
        feature_configuration = feature_configuration,
        cc_toolchain = cc_toolchain,
        user_link_flags = linkopts,
        # compilation_outpus contains all the Lisp code. If allow_save_lisp,
        # it's all in the -core.o file. Otherwise, the compiled Lisp code was
        # disassembled and reassembled, and this contains the output from that
        # plus the remainder of the Lisp core in the -core.o file.
        compilation_outputs = cc_common.merge_compilation_outputs(
            compilation_outputs = compilation_outputs,
        ),
        # linking_contexts contains all the C++ code to be linked in.
        linking_contexts = [
            # C++ code from transitive dependencies.
            lisp_info.cc_info.linking_context,
            # SBCL's C++ dependencies.
            ctx.attr.runtime[CcInfo].linking_context,
            # A custom malloc library gets linked in like any other library.
            # It's important that each binary gets a single malloc
            # implementation, so this does not get propagated to any of the
            # binary's consumers.
            malloc[CcInfo].linking_context,
        ],
        stamp = ctx.attr.stamp,
        output_type = "executable",
        additional_inputs = link_additional_inputs,
    )

    return _lisp_providers(
        ctx = ctx,
        lisp_info = lisp_info,
        fasl = compile.output_fasl,
        executable = linking_outputs.executable,
    )

lisp_binary = rule(
    implementation = _lisp_binary_impl,
    executable = True,
    attrs = _LISP_BINARY_ATTRS,
    fragments = ["cpp"],
    toolchains = [
        "@rules_cc//cc:toolchain_type",
    ],
    doc = """
Supports all of the same attributes as [`lisp_library`](#lisp_library), plus
additional attributes governing the behavior of the completed binary. The
[`main`](#lisp_binary-main) attribute defines behavior (generally specifying a
function to run with no arguments) when the binary is started. By default, it
runs `(cl-user::main)`.

Example:

    lisp_binary(
        name = "binary"
        srcs = ["binary.lisp"],
        main = "binary:main",
        deps = [":library"],
    )""",
)

lisp_test = rule(
    implementation = _lisp_binary_impl,
    executable = True,
    test = True,
    attrs = _LISP_TEST_ATTRS,
    fragments = ["cpp"],
    toolchains = [
        "@rules_cc//cc:toolchain_type",
    ],
    doc = """
Like [`lisp_binary`](#lisp_binary), for defining tests to be run with the
[`test`](https://docs.bazel.build/versions/master/user-manual.html#test)
command. The [`main`](#lisp_test-main) attribute should name a function which
runs the tests, outputs information about failing assertions, and exits with a
non-zero exit status if there are any failures.

Example:

    lisp_test(
        name = "library-test"
        srcs = ["library-test.lisp"],
        main = "library-test:run-tests",
        deps = [
            ":library",
            "//path/to/unit-test:framework",
        ],
    )""",
)

################################################################################
# Lisp Library
################################################################################

def _lisp_library_impl(ctx):
    """Lisp specific implementation for lisp_library rules."""
    verbose_level = max(
        getattr(ctx.attr, "verbose", 0),
        int(ctx.var.get("VERBOSE_LISP_BUILD", "0")),
    )
    verbosep = verbose_level > 0

    # buildozer: disable=print
    if verbosep:
        print("~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~")
        print("Library: %s" % ctx.label.name)

    compile = lisp_compile_srcs(
        ctx = ctx,
        srcs = ctx.files.srcs,
        deps = ctx.attr.deps,
        cdeps = ctx.attr.cdeps,
        image = ctx.attr.image,
        add_features = ctx.attr.add_features,
        nowarn = ctx.attr.nowarn,
        order = ctx.attr.order,
        compile_data = ctx.files.compile_data,
        verbose_level = verbose_level,
        instrument_coverage = ctx.attr.instrument_coverage,
    )

    return _lisp_providers(
        ctx = ctx,
        lisp_info = compile.lisp_info,
        fasl = compile.output_fasl,
    )

lisp_library = rule(
    implementation = _lisp_library_impl,
    attrs = _LISP_LIBRARY_ATTRS,
    fragments = ["cpp"],
    toolchains = [
        "@rules_cc//cc:toolchain_type",
    ],
    doc = """
The basic compilation unit for Lisp code. Can have Lisp dependencies
([`deps`](#lisp_library-deps)) and C/C++ dependencies
([`cdeps`](#lisp_library-cdeps)).

Example:

    lisp_test(
        name = "library"
        srcs = ["library.lisp"],
        cdeps = [":cc-dependency-ci"],
        deps = [":dependency"],
    )""",
)
