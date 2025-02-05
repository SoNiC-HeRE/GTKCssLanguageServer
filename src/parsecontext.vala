/* parsecontext.vala
 *
 * Copyright 2023 JCWasmx86 <JCWasmx86@t-online.de>
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program.  If not, see <http://www.gnu.org/licenses/>.
 *
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

[CCode (cname = "load_colors")]
public static extern string load_colors ();

[CCode (cname = "get_parser")]
public static extern TreeSitter.TSParser get_parser ();

[CCode (cname = "load_docs")]
public static extern string load_docs ();

[CCode (cname = "load_functions")]
public static extern string load_functions ();

[CCode (cname = "load_selectors")]
public static extern string load_selectors ();

namespace GtkCssLangServer {
    internal class ParseContext {
        Diagnostic[] diags;
        public Diagnostic[] enhanced_diags;
        string text;
        string uri;
        string[] lines;
        Node sheet;
        DataExtractor? extractor;
        Json.Object color_docs;
        Json.Object function_docs;
        Json.Object selector_docs;
        GLib.HashTable<string, string> property_docs;

        internal ParseContext (Diagnostic[] diags, string text, string uri) {
            this.property_docs = new GLib.HashTable<string, string> (GLib.str_hash, GLib.str_equal);
            this.diags = diags;
            this.text = text;
            this.uri = uri;
            this.lines = this.text.split ("\n");
            var t = get_parser ();
            var tree = t.parse_string (null, text, text.length);
            if (tree != null) {
                var root = tree.root_node ();
                this.sheet = to_node (root, text);
                this.sheet.set_parents ();
                tree.free ();
                this.extractor = new DataExtractor (text);
                this.sheet.visit (this.extractor);
            }
            var p = new Json.Parser ();
            p.load_from_data (load_colors ());
            this.color_docs = p.get_root ().get_object ();
            p = new Json.Parser ();
            p.load_from_data (load_docs ());
            var n = p.get_root ().get_object ();
            foreach (var k in n.get_members ()) {
                this.property_docs[k] = n.get_string_member (k);
            }
            p = new Json.Parser ();
            p.load_from_data (load_functions ());
            this.function_docs = p.get_root ().get_object ();
            p = new Json.Parser ();
            p.load_from_data (load_selectors ());
            this.selector_docs = p.get_root ().get_object ();
            this.enhanced_diags = new Diagnostic[0];
            this.enhanced_diagnostics ();
        }

        void enhanced_diagnostics () {
            if (this.sheet == null)
                return;
            var diags = new Diagnostic[0];
            foreach (var p in this.extractor.property_uses) {
                if (p.name == "animation-name") {
                    var r = p.node;
                    var name = r.value;
                    if (name is Identifier) {
                        var i = (Identifier) name;
                        info ("Found property-reference called animation-name with a name %s", i.id);
                        var found = false;
                        foreach (var keyframe in this.extractor.keyframes) {
                            if (keyframe.name == i.id) {
                                found = true;
                                break;
                            }
                        }
                        if (!found) {
                            diags += new Diagnostic () {
                                range = r.value.range,
                                severity = DiagnosticSeverity.Error,
                                message = "Unknown animation name \'" + i.id + "\'",
                                file = this.uri
                            };
                        }
                    }
                }
            }
            this.enhanced_diags = diags;
        }

        internal DocumentSymbol[] symbols () {
            var r = new DocumentSymbol[0];
            if (this.extractor == null)
                return r;
            foreach (var color in this.extractor.colors.get_keys ()) {
                var p = this.extractor.colors[color];
                r += new DocumentSymbol () {
                    name = color,
                    kind = SymbolKind.Field,
                    range = new Range () {
                        start = p,
                        end = p
                    }
                };
            }
            foreach (var kf in this.extractor.keyframes) {
                var range = kf.range;
                r += new DocumentSymbol () {
                    name = "@keyframes " + kf.name,
                    kind = SymbolKind.Field,
                    range = range
                };
            }
            return r;
        }

        internal Location ? find_declaration (Position p) {
            foreach (var ca in this.extractor.color_references) {
                if (ca.range.contains (p) && this.extractor.colors[ca.name] != null) {
                    return new Location () {
                               uri = this.uri,
                               range = new Range () {
                                   start = this.extractor.colors[ca.name],
                                   end = this.extractor.colors[ca.name],
                               }
                    };
                }
            }
            foreach (var pu in this.extractor.property_uses) {
                if (pu.name == "animation-name") {
                    var r = pu.node;
                    var name = r.value;
                    if (name.range.contains (p) && name is Identifier) {
                        var i = (Identifier) name;
                        foreach (var keyframe in this.extractor.keyframes) {
                            if (keyframe.name == i.id) {
                                return new Location () {
                                           uri = this.uri,
                                           range = keyframe.range
                                };
                            }
                        }
                    }
                }
            }
            return null;
        }

        internal Hover ? hover (uint line, uint character) {
            var p = new Position () {
                line = line,
                character = character
            };
            var hover_response = new Hover ();
            hover_response.contents = new MarkupContent ();
            hover_response.contents.kind = "markdown";
            foreach (var color in this.extractor.color_references) {
                if (color.range.contains (p)) {
                    var c = extract_color_docs (color.name);
                    if (c != null) {
                        hover_response.range = color.range;
                        hover_response.contents.value = c;
                        return hover_response;
                    }
                }
            }
            foreach (var pu in this.extractor.property_uses) {
                if (pu.range.contains (p)) {
                    var v = this.property_docs[pu.name];
                    if (v != null) {
                        hover_response.range = pu.range;
                        hover_response.contents.value = v;
                        return hover_response;
                    }
                }
            }
            foreach (var c in this.extractor.calls) {
                if (c.range.contains (p)) {
                    var v = this.function_docs.get_object_member (c.name);
                    if (v != null) {
                        hover_response.range = c.range;
                        hover_response.contents.value = v.get_string_member ("docs");
                        return hover_response;
                    }
                }
            }
            return null;
        }

        internal string ? extract_color_docs (string name) {
            foreach (var k in this.color_docs.get_members ()) {
                var obj = this.color_docs.get_object_member (k);
                var arr = obj.get_array_member ("colors");
                for (var i = 0; i < arr.get_length (); i++) {
                    var s = arr.get_string_element (i);
                    if (s == "@" + name)
                        return k + " colors:\n\n" + obj.get_string_member ("docs");
                }
            }
            return null;
        }

        private bool is_color (string line, uint pos) {
            while (pos > 0) {
                if (line[pos] == '@')
                    return true;
                if (line[pos] != '-' && !line[pos].isalnum () && line[pos] != '_')
                    break;
                pos--;
            }
            return false;
        }

        private bool is_property (string line, uint pos) {
            var in_streak = false;
            while (pos > 0) {
                if (line[pos] == 0) {
                    pos -= 1;
                    continue;
                }
                // E.g. if there is:
                // prop-name 1px;
                // Without the streaks, it would match
                // With it, we would go till the space between prop-name and 1px
                if (in_streak && !line[pos].isspace ())
                    return false;
                if (line[pos].isspace ()) {
                    if (!in_streak) {
                        in_streak = true;
                    }
                }
                if (!(line[pos].isspace () || line[pos] == '-' || line[pos].isalnum ()))
                    return false;
                pos--;
            }
            return true;
        }

        private bool is_selector (string line, uint pos) {
            while (pos > 0 && line[pos].isspace ())
                pos--;
            while (pos > 0) {
                if (line[pos] == ':')
                    return true;
                if (!line[pos].isalpha () && line[pos] != '-')
                    break;
                pos--;
            }
            return false;
        }

        private string ? fix_property (string line, uint pos, string old) {
            var old_pos = pos;
            while (pos > 0) {
                if (line[pos] == 0) {
                    pos -= 1;
                    continue;
                }
                if (line[pos] != '-' && !line[pos].isalnum ()) {
                    var s = line.substring (pos + 1, old_pos - pos - 1);
                    if (!old.has_prefix (s))
                        return null;
                    var offset = old_pos - pos - 1;
                    if (offset > old.length)
                        return null;
                    return old.substring (offset);
                }
                pos--;
            }
            return null;
        }

        internal CompletionItem[] complete (CompletionParams p) {
            if (p.position.line > this.lines.length)
                return new CompletionItem[0];
            var l = this.lines[p.position.line];
            if (p.position.character > l.length)
                return new CompletionItem[0];
            var ret = new CompletionItem[0];
            var c = p.position.character;
            if (c == 1 && l[0] == '@') {
                info ("Completing @define-color");
                ret += new CompletionItem ("@define-color", "define-color ${1:name} ${2:color};$0");
            } else if (c != 0 && (l[c - 1] == '@' || is_color (l, c))) {
                info ("Completing @color");
                foreach (var color in this.extractor.colors.get_keys ()) {
                    ret += new CompletionItem ("@" + color, color);
                }
                foreach (var k in this.color_docs.get_members ()) {
                    var obj = this.color_docs.get_object_member (k);
                    var arr = obj.get_array_member ("colors");
                    for (var i = 0; i < arr.get_length (); i++) {
                        var color = arr.get_string_element (i);
                        ret += new CompletionItem (color, color.substring (1));
                    }
                }
            } else if (is_property (l, c)) {
                info ("Completing properties");
                foreach (var k in this.property_docs.get_keys ()) {
                    // TODO: Add parameters to auto-completion.
                    var fixed = fix_property (l, c, k);
                    if (fixed == null)
                        continue;
                    ret += new CompletionItem (k, fixed + ": ${1:args};$0");
                }
            } else if (l[c] == ')' && c > 4 && l[c - 1] == '(' && l[c - 2] == 'r' && l[c - 3] == 'i' && l[c - 4] == 'd') {
                info ("Completing :dir(ltr|rtl)");
                ret += new CompletionItem ("ltr", "ltr");
                ret += new CompletionItem ("rtl", "rtl");
            } else if (l[c] == ')' && c > 5 && l[c - 1] == '(' && l[c - 2] == 'p' && l[c - 3] == 'o' && l[c - 4] == 'r' && l[c - 5] == 'd') {
                info ("Completing :drop(active)");
                ret += new CompletionItem ("active", "active");
            } else if (l[c] == ')' && c > 4 && l[c - 1] == '(' && l[c - 2] == 't' && l[c - 3] == 'o' && l[c - 4] == 'n') {
                info ("Completing :not(*)");
                ret += new CompletionItem ("*", "*");
            } else if (l.substring (0, c).has_suffix (":nth-last-child(") || l.substring (0, c).has_suffix (":nth-child(")) {
                info ("Completing :nth-(last-)child(even|odd)");
                ret += new CompletionItem ("even", "even");
                ret += new CompletionItem ("odd", "odd");
            } else if (is_selector (l, c)) {
                info ("Completing selectors");
                foreach (var sc in this.selector_docs.get_members ()) {
                    var obj = this.selector_docs.get_object_member (sc);
                    var is_func = obj.get_boolean_member ("function");
                    if (is_func) {
                        ret += new CompletionItem (":" + sc + "()", sc + "()");
                    } else {
                        ret += new CompletionItem (":" + sc, sc);
                    }
                }
            }
            return ret;
        }
    }
}
