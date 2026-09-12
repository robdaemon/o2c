--  Program lifecycle for the VM driver.
--
--  Same seam idea as VM_IO: the spec is shared, the body is per platform.
--  The host build just sets an exit status; the Aegir build must call
--  CLI.Init (args-page redirection trailer, cwd resolution) and exit
--  through CLI.Exit_With, which is what makes output compose with the
--  shell's redirection and pipes.
package VM_Platform is

   --  Called once before anything else.
   procedure Init;

   --  Terminate the process, reporting success or failure.
   procedure Exit_With (Ok : Boolean);

   --  Turn a path the user typed (or a default path) into one the file
   --  server understands.  The guest resolves it against the current
   --  directory via Aegir_User.CLI, the way every CLI program does; on the
   --  host a path is already a host path, so this is the identity.
   function Resolve_Path (Path : String) return String;

   --  How many times to try opening an image before giving up.  The host
   --  has one shot (an image is a static file there).  In the guest the
   --  compiler and the VM are spawned concurrently from System/Manifest -
   --  the spawner does not wait for one program before starting the next -
   --  so the VM waits for the compiler to finish writing the image.
   function Max_Input_Attempts return Natural;

   --  A test may ask for a smaller scheduling quantum by setting
   --  O2C_QUANTUM in the environment.  0 means "no opinion".  The guest has
   --  no environment, so its body always answers 0 - which is the point of
   --  the seam: the shared driver asks, and only the host can answer.
   function Quantum_Override return Natural;

   --  Delete a file.  The host deletes it directly; the guest must ask its
   --  file server, which is a capability it holds.  Oakwood's Files.Delete
   --  has no status to report, so a failure here is not distinguishable from
   --  success at the dialect level - deliberate, and the reason this is a
   --  procedure rather than a function returning a code.
   procedure Delete_File (Path : String);

   --  Rename within a volume.  Same shape and same reasoning as Delete_File:
   --  no status to report, so a procedure.
   procedure Rename_File (From, To : String);

   --  Environment variables.  This is the case the seam was built for: the
   --  host has a real environment, the guest keeps variables as ENV:<Name>
   --  files and reaches them through CLI.  The shared VM asks; only the
   --  platform knows where the answer lives.  An unset name reads as the
   --  empty string, which is what Aegir's CLI.Get_Env returns and what
   --  Oakwood's Env.Get expects.
   function Get_Env (Name : String) return String;
   procedure Set_Env (Name, Value : String);

   --  The N-th argument of the INTERPRETED PROGRAM, 1-based, copied into Buf
   --  without a terminator.  Returns its length, or -1 when N is out of range.
   --  Numbering is the platform's business: the host's own argument 1 is the
   --  image so it offsets, while the guest's arguments are the program's own.
   function Arg_Get (N : Natural; Buf : out String) return Integer;

   --  One line of the program's input.  The guest reads it through
   --  Aegir_User.CLI, which is the same call the Ada backend's generated
   --  helper makes; the host reads its own stdin.  E is true at end of input,
   --  and then L is 0.  This is why In needs the seam where XYplane did not:
   --  input genuinely differs between the two.
   procedure Get_Line (S : out String; L : out Natural; E : out Boolean);

end VM_Platform;
