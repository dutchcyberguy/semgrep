(*
   'semgrep scan' subcommand

   Translated from scan.py
*)

open Printf

(* Provide 'Term', 'Arg', and 'Manpage' modules. *)
open Cmdliner

(*
   The result of parsing a 'semgrep scan' command.

   Field order: alphabetic.
   This facilitates insertion, deduplication, and removal
   of options.
*)
type conf = {
  autofix : bool;
  baseline_commit : string option;
  config : string;
  debug : bool;
  exclude : string list;
  include_ : string list;
  lang : string option;
  max_memory_mb : int;
  max_target_bytes : int;
  metrics : Metrics.State.t;
  num_jobs : int;
  optimizations : bool;
  pattern : string option;
  quiet : bool;
  respect_git_ignore : bool;
  target_roots : string list;
  timeout : float;
  timeout_threshold : int;
  verbose : bool;
}

let get_cpu_count () =
  (* Parmap subtracts 1 from the number of detected cores.
     This comes with no guarantees. *)
  max 1 (Parmap.get_default_ncores () + 1)

let default =
  {
    autofix = false;
    baseline_commit = None;
    config = "auto";
    debug = false;
    exclude = [];
    include_ = [];
    lang = None;
    max_memory_mb = 0;
    max_target_bytes = 1_000_000;
    metrics = Metrics.State.Auto;
    num_jobs = get_cpu_count ();
    optimizations = false;
    pattern = None;
    quiet = false;
    respect_git_ignore = true;
    target_roots = [ "." ];
    timeout = 30.;
    timeout_threshold = 3;
    verbose = false;
  }

(*************************************************************************)
(* Various utilities *)
(*************************************************************************)

let _validate_lang option lang_str =
  match lang_str with
  | None -> failwith (sprintf "%s and -l/--lang must both be specified" option)
  | Some lang -> lang

(*************************************************************************)
(* Command-line parsing: turn argv into conf *)
(*************************************************************************)

let o_autofix =
  CLI_common.negatable_flag [ "a"; "autofix" ] ~neg_options:[ "no-autofix" ]
    ~default:default.autofix
    ~doc:
      {|Apply autofix patches. WARNING: data loss can occur with this flag.
Make sure your files are stored in a version control system. Note that
this mode is experimental and not guaranteed to function properly.
|}

let o_baseline_commit =
  let info =
    Arg.info [ "baseline_commit" ]
      ~doc:
        {|Only show results that are not found in this commit hash. Aborts run
if not currently in a git directory, there are unstaged changes, or
given baseline hash doesn't exist.
|}
      ~env:(Cmd.Env.info "SEMGREP_BASELINE_COMMIT")
    (* TODO: support also SEMGREP_BASELINE_REF; unfortunately cmdliner
             supports only one environment variable per option *)
  in
  Arg.value (Arg.opt Arg.(some string) None info)

let o_config =
  let info =
    Arg.info [ "c"; "f"; "config" ]
      ~env:(Cmd.Env.info "SEMGREP_RULES")
      ~doc:
        {|YAML configuration file, directory of YAML files ending in
.yml|.yaml, URL of a configuration file, or Semgrep registry entry name.

Use --config auto to automatically obtain rules tailored to this project;
your project URL will be used to log in to the Semgrep registry.

To run multiple rule files simultaneously, use --config before every YAML,
URL, or Semgrep registry entry name.
For example `semgrep --config p/python --config myrules/myrule.yaml`

See https://semgrep.dev/docs/writing-rules/rule-syntax for information on
configuration file format.
|}
  in
  Arg.value (Arg.opt Arg.string default.config info)

let o_debug =
  let info =
    Arg.info [ "debug" ]
      ~doc:{|All of --verbose, but with additional debugging information.|}
  in
  Arg.value (Arg.flag info)

let o_exclude =
  let info =
    Arg.info [ "exclude" ]
      ~doc:
        {|Filter files or directories by path. The argument is a
glob-style pattern such as 'foo.*' that must match the path. This is
an extra filter in addition to other applicable filters. For example,
specifying the language with '-l javascript' migh preselect files
'src/foo.jsx' and 'lib/bar.js'.  Specifying one of '--include=src',
'-- include=*.jsx', or '--include=src/foo.*' will restrict the
selection to the single file 'src/foo.jsx'. A choice of multiple '--
include' patterns can be specified. For example, '--include=foo.*
--include=bar.*' will select both 'src/foo.jsx' and
'lib/bar.js'. Glob-style patterns follow the syntax supported by
python, which is documented at
https://docs.python.org/3/library/glob.html
|}
  in
  Arg.value (Arg.opt_all Arg.string [] info)

let o_include =
  let info =
    Arg.info [ "include" ]
      ~doc:
        {|Filter files or directories by path. The argument is a
glob-style pattern such as 'foo.*' that must match the path. This is
an extra filter in addition to other applicable filters. For example,
specifying the language with '-l javascript' migh preselect files
'src/foo.jsx' and 'lib/bar.js'.  Specifying one of '--include=src',
'-- include=*.jsx', or '--include=src/foo.*' will restrict the
selection to the single file 'src/foo.jsx'. A choice of multiple '--
include' patterns can be specified. For example, '--include=foo.*
--include=bar.*' will select both 'src/foo.jsx' and
'lib/bar.js'. Glob-style patterns follow the syntax supported by
python, which is documented at
https://docs.python.org/3/library/glob.html
|}
  in
  Arg.value (Arg.opt_all Arg.string [] info)

let o_max_target_bytes =
  let info =
    Arg.info [ "max-target-bytes" ]
      ~doc:
        {|Maximum size for a file to be scanned by Semgrep, e.g
'1.5MB'. Any input program larger than this will be ignored. A zero or
negative value disables this filter. Defaults to 1000000 bytes.
|}
  in
  (* TODO: support '1.5MB' and such *)
  Arg.value (Arg.opt Arg.int default.max_target_bytes info)

let o_lang =
  let info =
    Arg.info [ "lang" ]
      ~doc:
        {|Parse pattern and all files in specified language.
Must be used with -e/--pattern.
|}
  in
  Arg.value (Arg.opt Arg.(some string) None info)

let o_max_memory_mb =
  let info =
    Arg.info [ "max-memory-mb" ]
      ~doc:
        {|Maximum system memory to use running a rule on a single file
in MB. If set to 0 will not have memory limit. Defaults to 0.
|}
  in
  Arg.value (Arg.opt Arg.int default.max_memory_mb info)

let o_metrics =
  let info =
    Arg.info [ "metrics" ]
      ~env:(Cmd.Env.info "SEMGREP_SEND_METRICS")
      ~doc:
        {|Configures how usage metrics are sent to the Semgrep server. If
'auto', metrics are sent whenever the --config value pulls from the
Semgrep server. If 'on', metrics are always sent. If 'off', metrics
are disabled altogether and not sent. If absent, the
SEMGREP_SEND_METRICS environment variable value will be used. If no
environment variable, defaults to 'auto'.
|}
  in
  Arg.value (Arg.opt Metrics.State.converter default.metrics info)

let o_num_jobs =
  let info =
    Arg.info [ "j"; "jobs" ]
      ~doc:
        {|Number of subprocesses to use to run checks in
parallel. Defaults to the number of cores detected on the system.
|}
  in
  Arg.value (Arg.opt Arg.int default.num_jobs info)

let o_optimizations =
  let parse = function
    | "all" -> Ok true
    | "none" -> Ok false
    | other -> Error (sprintf "unsupported value %S" other)
  in
  let print fmt = function
    | true -> Format.pp_print_string fmt "all"
    | false -> Format.pp_print_string fmt "none"
  in
  let converter = Arg.conv' (parse, print) in
  let info =
    Arg.info [ "optimizations" ]
      ~doc:
        {|Turn on/off optimizations. Default = 'all'.
Use 'none' to turn all optimizations off.
|}
  in
  Arg.value (Arg.opt converter default.optimizations info)

let o_pattern =
  let info =
    Arg.info [ "e"; "pattern" ]
      ~doc:
        {|Parse pattern and all files in specified language.
Must be used with -e/--pattern.
|}
  in
  Arg.value (Arg.opt Arg.(some string) None info)

let o_quiet =
  let info = Arg.info [ "q"; "quiet" ] ~doc:{|Only output findings.|} in
  Arg.value (Arg.flag info)

let o_respect_git_ignore =
  CLI_common.negatable_flag [ "use-git-ignore" ]
    ~neg_options:[ "no-git-ignore" ] ~default:default.respect_git_ignore
    ~doc:
      {|Skip files ignored by git. Scanning starts from the root
folder specified on the Semgrep command line. Normally, if the
scanning root is within a git repository, only the tracked files and
the new files would be scanned. Git submodules and git- ignored files
would normally be skipped. --no-git-ignore will disable git-aware
filtering. Setting this flag does nothing if the scanning root is not
in a git repository.
|}

let o_target_roots =
  let info =
    Arg.info [] ~docv:"TARGETS"
      ~doc:{|Files or folders to be scanned by semgrep.
|}
  in
  Arg.value (Arg.pos_all Arg.string default.target_roots info)

let o_timeout =
  let info =
    Arg.info [ "timeout" ]
      ~doc:
        {|Maximum time to spend running a rule on a single file in
seconds. If set to 0 will not have time limit. Defaults to 30 s.
|}
  in
  Arg.value (Arg.opt Arg.float default.timeout info)

let o_timeout_threshold =
  let info =
    Arg.info [ "timeout-threshold" ]
      ~doc:
        {|Maximum number of rules that can time out on a file before
the file is skipped. If set to 0 will not have limit. Defaults to 3.
|}
  in
  Arg.value (Arg.opt Arg.int default.timeout_threshold info)

let o_verbose =
  let info =
    Arg.info [ "v"; "verbose" ]
      ~doc:
        {|Show more details about what rules are running, which files
failed to parse, etc.
|}
  in
  Arg.value (Arg.flag info)

(*** Subcommand 'scan' ***)

let cmdline_term run =
  let combine autofix baseline_commit config debug exclude include_ lang
      max_memory_mb max_target_bytes metrics num_jobs optimizations pattern
      quiet respect_git_ignore target_roots timeout timeout_threshold verbose =
    run
      {
        autofix;
        baseline_commit;
        config;
        debug;
        exclude;
        include_;
        lang;
        max_memory_mb;
        max_target_bytes;
        metrics;
        num_jobs;
        optimizations;
        pattern;
        quiet;
        respect_git_ignore;
        target_roots;
        timeout;
        timeout_threshold;
        verbose;
      }
  in
  Term.(
    const combine $ o_autofix $ o_baseline_commit $ o_config $ o_debug
    $ o_exclude $ o_include $ o_lang $ o_max_memory_mb $ o_max_target_bytes
    $ o_metrics $ o_num_jobs $ o_optimizations $ o_pattern $ o_quiet
    $ o_respect_git_ignore $ o_target_roots $ o_timeout $ o_timeout_threshold
    $ o_verbose)

let doc = "run semgrep rules on files"

(* TODO: document the exit codes as defined in Error.mli *)
let man =
  [
    `S Manpage.s_description;
    `P
      "Searches TARGET paths for matches to rules or patterns. Defaults to \
       searching entire current working directory.";
    `P "To get started quickly, run";
    `Pre "semgrep --config auto .";
    `P
      "This will automatically fetch rules for your project from the Semgrep \
       Registry. NOTE: Using `--config auto` will log in to the Semgrep \
       Registry with your project URL.";
    `P "For more information about Semgrep, go to https://semgrep.dev.";
    `P
      "NOTE: By default, Semgrep will report pseudonymous usage metrics to its \
       server if you pull your configuration from the Semgrep registy. To \
       learn more about how and why these metrics are collected, please see \
       https://semgrep.dev/docs/metrics. To modify this behavior, see the \
       --metrics option below.";
  ]
  @ CLI_common.help_page_bottom

let parse_and_run (argv : string array) (run : conf -> Exit_code.t) =
  let run conf = CLI_common.safe_run run conf |> Exit_code.to_int in
  let info = Cmd.info "semgrep scan" ~doc ~man in
  run |> cmdline_term |> Cmd.v info |> Cmd.eval' ~argv |> Exit_code.of_int
