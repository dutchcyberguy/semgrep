open Common

type autofix_printer_test_case = {
  target : string;
  pattern : string;
  fix_pattern : string;
  expected : string;
}

(* Test suite for the python autofix printer.
 *
 * This runs Semgrep to get a pattern match, then renders the fix. However, it
 * feeds in fake strings for the target and fix pattern contents, so that we can
 * test which parts were lifted from the original source and which parts were
 * printed from scratch. This functionality is a key part of the autofix
 * printer, and this allows us to test that it is being done for all of the
 * nodes we expect.
 *
 * Even if our printers become excellent and handle nearly every case, we still
 * have no plans to include comments, mimic the original formatting, or do any
 * kind of nicely formatted pretty-printing. And, there is always the
 * possibility of a bug in the printer. For these reasons, it's important that
 * we minimize the amount of printing we have to do by lifting the original text
 * wherever possible. However, it's not obvious in ordinary autofix tests where
 * the text in the rendered fix came from. So, it would be easy to miss a bug
 * that led to a particular node getting printed from scratch rather than lifted
 * from the original text.
 *
 * This does not test that we lift the correct ranges from the original target
 * or fix pattern, just that we lift the correct number of characters. The tests
 * in `semgrep-core/tests` exercise the system as a whole, and ensure that the
 * fixes tested there are correct.
 *
 * TODO generalize the test runner once we have multiple languages to test
 *)
let test_python_autofix_printer () =
  let check { target; pattern; fix_pattern; expected } =
    Common2.with_tmp_file ~str:target ~ext:"py" (fun target_file ->
        let matches =
          Unit_engine.match_pattern ~lang:Lang.Python
            ~hook:(fun _ -> ())
            ~file:target_file ~pattern ~fix_pattern:(Some fix_pattern)
        in
        (* To keep it simple, we make sure that each example here has only a
         * single match. *)
        let match_ =
          match matches with
          | [ m ] -> m
          | lst ->
              failwith
                (spf
                   "wrong number of matches for `%s`. expected exactly 1, got \
                    %d"
                   target (List.length lst))
        in
        let fix_pattern_ast =
          Parse_pattern.parse_pattern Lang.Python fix_pattern
        in
        let metavars = match_.env in
        let fixed_pattern_ast =
          match
            Autofix_metavar_replacement.replace_metavars metavars
              fix_pattern_ast
          with
          | Ok x -> x
          | Error e ->
              failwith (spf "Failed to replace metevars for `%s`:\n%s" target e)
        in
        (* Make a fake string to use when printing instead of the target. Fill
         * it with 't' so that we can identify it in the final output. *)
        let fake_target_contents = String.make (String.length target) 't' in
        (* Same as above, but for the fix pattern *)
        let fake_fix_pattern = String.make (String.length fix_pattern) 'p' in
        let fix_text =
          match
            Autofix_printer.print_ast ~lang:Lang.Python ~metavars
              ~target_contents:(lazy fake_target_contents)
              ~fix_pattern_ast ~fix_pattern:fake_fix_pattern fixed_pattern_ast
          with
          | Ok x -> x
          | Error e ->
              failwith (spf "Failed to print for test case `%s`:\n%s" target e)
        in
        (* Replace the fake target contents with the rendered fix *)
        let start, end_ =
          let start, end_ = match_.Pattern_match.range_loc in
          let _, _, end_charpos = Parse_info.get_token_end_info end_ in
          (start.Parse_info.charpos, end_charpos)
        in
        let full_fixed_text =
          let before = Str.first_chars fake_target_contents start in
          let after = Str.string_after fake_target_contents end_ in
          before ^ fix_text ^ after
        in
        Alcotest.(check string) fix_pattern expected full_fixed_text)
  in
  List.iter check
    [
      (* TODO foobar should be lifted from the pattern *)
      {
        target = "foo";
        pattern = "foo";
        fix_pattern = "foobar";
        expected = "foobar";
      };
      (* TODO baz should be lifted from the pattern *)
      {
        target = "foo + bar";
        pattern = "bar";
        fix_pattern = "baz";
        expected = "ttttttbaz";
      };
      (* TODO bar should be lifted from the pattern *)
      {
        target = "foo(1, 42, 423)";
        pattern = "foo(1, $...REST)";
        fix_pattern = "bar(baz, $...REST)";
        expected = "bar(ppp, tt, ttt)";
      };
    ]

let tests =
  Testutil.pack_tests "autofix printer"
    [ ("test python autofix printer", test_python_autofix_printer) ]
