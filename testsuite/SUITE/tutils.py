# ***************************************************************************
# **                      TEST-COMMON UTILITY functions                    **
# ***************************************************************************

# This module exposes common utility functions to every test instance.  They
# depend on the current test context and are not suitable for the toplevel
# suite driver.

# ***************************************************************************

# Expose a few other items as a test util-facilities as well

from SUITE import control
from SUITE.control import BUILDER, XCOV, LANGINFO, language_info, need_libsupport
from SUITE.context import *
from SUITE.qdata import QLANGUAGES

# Then mind our own buisness

from SUITE.cutils import *
from gnatpython.fileutils import unixpath

VALGRIND  = 'valgrind' + env.host.os.exeext

# -------------------------
# -- gprbuild_gargs_with --
# -------------------------

def gprbuild_gargs_with (thisgargs):
    """Compute and return all the toplevel gprbuild arguments to pass. Account
       for specific requests in THISGARGS."""

    # Force a few bits useful for practical reasons and without influence on
    # code generation, then add our testsuite configuration options (selecting
    # target model and board essentially).

    return [
        '-f',               # always rebuild
        '-XSTYLE_CHECKS=',  # style checks off
        '-p'                # create missing directories (obj, typically)
        ] + (
        thistest.gprconfoptions
        + thistest.gprvaroptions
        + to_list (thisgargs)
        )

# -------------------------
# -- gprbuild_cargs_with --
# -------------------------

def gprbuild_cargs_with (thiscargs):
    """Compute and return all the cargs arguments to pass on gprbuild
       invocations, including language agnostic and language specific ones
       (-cargs and -cargs:<lang>). Account for specific requests in
       THISCARGS."""

    # To make sure we have a clear view of what options are used for a
    # qualification run, qualification tests are not allowed to state
    # compilation flags of their own

    thistest.stop_if (thiscargs and thistest.options.qualif_level,
        FatalError("CARGS requested for qualification test. Forbidden."))

    all_cargs = ["-cargs"] + (
        to_list(BUILDER.COMMON_CARGS)
        + to_list (thistest.suite_cargs_for (lang=None))
        + to_list (thiscargs)
        )

    [all_cargs.extend (
            ["-cargs:%s" % lang] + to_list (thistest.suite_cargs_for (lang)))
     for lang in QLANGUAGES
     ]

    return all_cargs

# -------------------------
# -- gprbuild_largs_with --
# -------------------------

def gprbuild_largs_with (thislargs):
    """Compute and return all the largs gprbuild arguments to pass.
       Account for specific requests in THISLARGS."""

    all_largs = to_list (thislargs)
    if all_largs:
        all_largs.insert (0, '-largs')

    return all_largs

# --------------
# -- gprbuild --
# --------------

def gprbuild(project, extracargs=None, gargs=None, largs=None):
    """Cleanup & build the provided PROJECT file using gprbuild, passing
    GARGS/CARGS/LARGS as gprbuild/cargs/largs command-line switches, in
    addition to the switches required by the infrastructure or provided on
    the testsuite commandline for the --cargs family.

    The *ARGS arguments may be either: None, a string containing
    a space-separated list of options, or a list of options."""

    # Fetch options, from what is requested specifically here
    # or from command line requests

    all_gargs = gprbuild_gargs_with (thisgargs=gargs)
    all_largs = gprbuild_largs_with (thislargs=largs)
    all_cargs = gprbuild_cargs_with (thiscargs=extracargs)

    # Now cleanup, do build and check status

    thistest.cleanup(project)

    ofile = "gprbuild.out"
    p = Run (
        to_list(BUILDER.BASE_COMMAND) + ['-P%s' % project]
        + all_gargs + all_cargs + all_largs,
        output=ofile, timeout=thistest.options.timeout
        )
    thistest.stop_if (
        p.status != 0, FatalError("gprbuild exit in error", ofile))

# ------------
# -- gprfor --
# ------------
def gprfor(
    mains, prjid="gen", srcdirs="src",
    main_cargs=None, langs=None, deps=(), extra=""
    ):
    """Generate a simple PRJID.gpr project file to build executables for each
    main source file in the MAINS list, sources in SRCDIRS. Inexistant
    directories in SRCDIRS are ignored. Assume the set of languages is LANGS
    when specified; infer from the mains otherwise. Add EXTRA, if any, at the
    end of the project file contents and return the gpr file name.
    """

    deps = '\n'.join (
        ["with \"%s\";" % dep for dep in deps])

    mains = to_list(mains)
    srcdirs = to_list(srcdirs)
    langs = to_list(langs)

    # Fetch the support project file template
    template = contents_of (os.path.join (ROOT_DIR, "template.gpr"))

    # Instanciate the template fields.

    # Turn the list of main sources into the proper comma separated sequence
    # of string literals for the Main GPR attribute.

    gprmains = ', '.join(['"%s"' % m for m in mains])

    # Likewise for source dirs. Filter on existence, to allow widening the set
    # of tentative dirs while preventing complaints from gprbuild about
    # inexistent ones. Remove a lone trailing comma, which happens when none
    # of the provided dirs exists and would produce an invalid gpr file.

    srcdirs = ', '.join(['"%s"' % d for d in srcdirs if os.path.exists(d)])
    srcdirs = srcdirs.rstrip(', ')

    # Determine the language(s) from the mains.

    languages_l = langs or set(
        [language_info(main).name for main in mains]
        )

    languages = ', '.join(['"%s"' %l for l in languages_l])

    # The base project file we need to extend, and the way to refer to it
    # from the project contents. This provides a default last chance handler
    # on which we rely to detect termination on exception occurrence.

    basegpr = (
        ("%s/support/base" % ROOT_DIR) if control.need_libsupport ()
        else None)

    baseref = (
        (basegpr.split('/')[-1] + ".") if basegpr else "")

    # If we have specific flags for the mains, append them. This is
    # typically something like
    #
    #  for Switches("test_blob.adb") use
    #    Compiler'Default_Switches("Ada") & ("-fno-inline")

    compswitches = '\n'.join (
        ['for Switches("%s") use \n'
         '  Compiler\'Default_Switches ("%s") & (%s);' % (
                main, language_info(main).name, ','.join(
                    ['"%s"' % carg for carg in to_list(main_cargs)]))
         for main in mains]
        ) + '\n'

    # Now instanciate, dump the contents into the target gpr file and return

    gprtext = template % {
        'prjname': prjid,
        'extends': ('extends "%s"' % basegpr) if basegpr else "",
        'srcdirs': srcdirs,
        'compswitches': compswitches,
        'languages' : languages,
        'gprmains': gprmains,
        'deps': deps,
        'extra': extra}

    return text_to_file (text = gprtext, filename = prjid + ".gpr")

# ----------------------------------------------
# -- exename_for, tracename_for, dmapname_for --
# ----------------------------------------------

# Abstract away the possible presence of extensions at the end of executable
# names depending on the target, e.g. ".out" for vxworks.

# PGNNAME is a program name, in the main subprogram name sense. An empty
# PGMNAME is allowed, in which case the functions return only the extensions.

def exename_for (pgmname):
    return (pgmname + thistest.tinfo.exeext) if thistest.tinfo else pgmname

def tracename_for (pgmname):
    return exename_for (pgmname) + ".trace"

def dmapname_for (pgmname):
    return exename_for (pgmname) + ".dmap"

# -----------------------------
# -- exepath_to, unixpath_to --
# -----------------------------

# Those two are very similar. The unix version is mostly useful on Windows for
# tests that are going to search for exe filenames in outputs using regular
# expressions, where backslashes as directory separators introduce confusion.

def exepath_to (pgmname):
    """Return the absolute path to the executable file expected
    in the current directory for a main subprogram PGMNAME."""

    return os.path.abspath(exename_for(pgmname))

def unixpath_to (pgmname):
    """Return the absolute path to the executable file expected in the
    current directory for a main subprogram PGMNAME, unixified."""

    return unixpath(os.path.abspath(exename_for(pgmname)))

# --------------------
# -- maybe_valgrind --
# --------------------
def maybe_valgrind(command):
    """Return the input COMMAND list, with 'valgrind -q' prepended if
    valgrind is requested.  valgrind will have to be available for the
    execution to proceed.
    """
    return (
        ([VALGRIND, '-q'] + command) if thistest.options.enable_valgrind
        else command
        )

# ----------
# -- xcov --
# ----------
def xcov(args, out=None, inp=None, register_failure=True):
    """Run xcov with arguments ARGS, timeout control, valgrind control if
    available and enabled, output directed to OUT and failure registration
    if register_failure is True. Return the process status descriptor. ARGS
    may be a list or a whitespace separated string."""

    # make ARGS a list from whatever it is, to allow unified processing
    args = to_list (args)

    if thistest.options.trace_dir is not None:
        # Bootstrap - run xcov under xcov

        if len (args) > 0 and args[0] == 'coverage':
            thistest.current_test_index += 1
            args = ['run', '-t', 'i686-pc-linux-gnu',
                    '-o', os.path.join(thistest.options.trace_dir,
                                       str(thistest.current_test_index)
                                       + '.trace'),
                    which(XCOV), '-eargs'] + args

    # Execute, check status, raise on error and return otherwise

    # The gprvar options are only needed for the "libsupport" part of our
    # projects, pointless wrt coverage run or analysis activities.

    p = Run(maybe_valgrind([XCOV]) + args,
            output=out, input=inp, timeout=thistest.options.timeout)

    thistest.stop_if(
        register_failure and p.status != 0,
        FatalError('"%s ' % XCOV + ' '.join(args) + '" exit in error', out))
    return p

# ----------
# -- xrun --
# ----------
def xrun(args, out=None, register_failure=True):
    """Run <xcov run> with arguments ARGS for the current target."""

    # We special case xcov --run to pass an extra --target option and
    # force a dummy input to prevent mysterious qemu misbehavior when
    # input is a terminal.

    nulinput = "devnul"
    touch(nulinput)

    # Compute our --target argument to xcov run.  If we have a specific
    # target board specified, use that.  Fallback on our general target
    # triplet otherwise.

    if thistest.options.board:
        targetarg = thistest.options.board
    else:
        targetarg = env.target.triplet

    # Compute our full list of arguments to gnatcov now, which might need
    # to include an extra --kernel

    allargs = ['run', '--target=' + targetarg]

    if thistest.options.kernel:
        allargs.append ('--kernel=' + thistest.options.kernel)

    allargs.extend (to_list(args))

    return xcov (
        allargs, inp=nulinput, out=out,
        register_failure=register_failure)

# --------
# -- do --
# --------
def do(command):
    """Execute COMMAND. Abort and dump output on failure. Return output
    otherwise."""

    ofile = "cmd_.out"
    p = Run(to_list (command), output=ofile)

    thistest.stop_if(p.status != 0,
        FatalError("command '%s' failed" % command, ofile))

    return contents_of(ofile)

# -------------
# -- compile --
# -------------
def compile(source, options):
    """Compile SOURCE with the target compiler, passing OPTIONS on the
    command line."""
    do("%s-gcc -c %s %s"  % (env.target.triplet, options, source))

# -----------
# -- frame --
# -----------
class frame:

    def register(self, text):
        if len(text) > self.width:
            self.width = len(text)

    def display(self):
        thistest.log('\n' * self.pre + self.char * (self.width + 6))
        [thistest.log(
            "%s %s %s" % (
            self.char * 2, text.center(self.width), self.char*2))
         for text in self.lines]
        thistest.log(self.char * (self.width + 6) + '\n' * self.post)

    def __init__(self, text, char='o', pre=1, post=1):
        self.pre  = pre
        self.post = post
        self.char = char

        self.width = 0
        self.lines = text.split('\n')
        [self.register(text) for text in self.lines]

