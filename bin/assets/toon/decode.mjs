// Decode one TOON document to JSON, so nothing in `bin\` ever has to read TOON itself.
//
// WHY THIS EXISTS. `no-mistakes axi status` prints TOON and has no JSON mode, so a reader on our
// side either takes a decoder or hand-rolls one. Hand-rolling it is the standing criterion 12
// failure outright: TOON quotes strings with its own backslash escape set rather than CSV's
// doubled quote, and a review finding's `description` is free text a reviewer wrote, so the input
// set never closes. `bin\GateRun.psm1` therefore runs this and reads only the JSON that comes
// back - the same boundary `bin\Usage.psm1` keeps to `quota-axi`'s JSON and `bin\Ci.psm1` keeps
// to `gh`.
//
// Strict decoding is the default and is left on deliberately. It enforces the declared row and
// item counts, rejects tab indentation, and rejects an invalid escape - so a truncated or
// corrupted capture raises an error here instead of arriving upstairs as a short table that looks
// complete. An unreadable input has to read as unreadable.
//
// Usage: node decode.mjs <path-to-toon-file>
// Prints JSON on stdout and exits 0, or prints one line naming the failure on stderr and exits 1.
//
// toon.mjs beside this file is @toon-format/toon v4.1.1, the reference implementation, vendored
// verbatim under the MIT licence in LICENSE beside it. It is vendored rather than installed
// because it is a single file with no dependencies of its own, and because a reader that stops
// working when a global package is missing is a reader nobody can rely on.

import { readFileSync } from 'node:fs';
import { decode } from './toon.mjs';

const path = process.argv[2];
if (!path) {
  process.stderr.write('decode.mjs needs the path of a file holding the TOON to decode.\n');
  process.exit(1);
}

let text;
try {
  text = readFileSync(path, 'utf8');
} catch (e) {
  process.stderr.write(`The captured output could not be read back from ${path}: ${e.message}\n`);
  process.exit(1);
}

// A byte order mark survives a UTF-8 read as U+FEFF and is not part of the document. TOON would
// see it as the first character of the first key and refuse a document that is perfectly good.
if (text.charCodeAt(0) === 0xfeff) text = text.slice(1);

try {
  process.stdout.write(JSON.stringify(decode(text)));
} catch (e) {
  process.stderr.write(`${e.message}\n`);
  process.exit(1);
}
