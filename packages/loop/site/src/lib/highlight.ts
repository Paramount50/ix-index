export type TokenKind =
  | 'cmd'
  | 'arg'
  | 'flag'
  | 'string'
  | 'var'
  | 'op'
  | 'path'
  | 'comment'
  | 'space';

export type Token = { kind: TokenKind; text: string };

const PATH_RE = /^(?:~|\.{1,2})?(?:\/[^\s|;&<>'"`#]+)+/;
const FLAG_RE = /^--?[A-Za-z][\w-]*/;
const VAR_RE = /^\$(?:\{[^}]*\}?|\w+|\(\(?)/;
const STR_DQ_RE = /^"(?:[^"\\]|\\.)*"?/;
const STR_SQ_RE = /^'(?:[^'\\]|\\.)*'?/;
const STR_BT_RE = /^`(?:[^`\\]|\\.)*`?/;
const OP_RE = /^(?:\|\||&&|>>|<<<|<<|;|\||>|<|&)/;
const WORD_RE = /^[^\s|;&<>'"`#]+/;
const COMMENT_RE = /^#[^\n]*/;
const SPACE_RE = /^\s+/;

export const tokenize = (text: string): Token[] => {
  const tokens: Token[] = [];
  let i = 0;
  let nextIsCmd = true;
  while (i < text.length) {
    const slice = text.slice(i);
    let m: RegExpExecArray | null;
    if ((m = COMMENT_RE.exec(slice))) {
      tokens.push({ kind: 'comment', text: m[0] });
    } else if ((m = STR_DQ_RE.exec(slice)) || (m = STR_SQ_RE.exec(slice)) || (m = STR_BT_RE.exec(slice))) {
      tokens.push({ kind: 'string', text: m[0] });
      nextIsCmd = false;
    } else if ((m = VAR_RE.exec(slice))) {
      tokens.push({ kind: 'var', text: m[0] });
      nextIsCmd = false;
    } else if ((m = OP_RE.exec(slice))) {
      tokens.push({ kind: 'op', text: m[0] });
      nextIsCmd = true;
    } else if ((m = SPACE_RE.exec(slice))) {
      tokens.push({ kind: 'space', text: m[0] });
    } else if ((m = FLAG_RE.exec(slice))) {
      tokens.push({ kind: 'flag', text: m[0] });
      nextIsCmd = false;
    } else if ((m = PATH_RE.exec(slice))) {
      tokens.push({ kind: nextIsCmd ? 'cmd' : 'path', text: m[0] });
      nextIsCmd = false;
    } else if ((m = WORD_RE.exec(slice))) {
      tokens.push({ kind: nextIsCmd ? 'cmd' : 'arg', text: m[0] });
      nextIsCmd = false;
    } else {
      tokens.push({ kind: 'arg', text: slice[0] });
      i += 1;
      continue;
    }
    i += m[0].length;
  }
  return tokens;
};
