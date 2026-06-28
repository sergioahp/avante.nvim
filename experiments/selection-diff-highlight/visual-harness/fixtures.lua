return {
  word_swap = {
    filetype = "lua",
    start_lnum = 5,
    prefix = {
      "local function build_message(user)",
      '  local prefix = "status"',
      "  local enabled = true",
      "",
    },
    before = {
      '  local mode = "draft"',
      "  local retries = 2",
      '  return prefix .. ":" .. mode .. ":" .. retries',
    },
    after = {
      '  local mode = "final"',
      "  local retries = 3",
      '  return prefix .. ":" .. mode .. ":" .. retries',
    },
    suffix = {
      "end",
      "",
      'return build_message({ name = "Ada" })',
    },
  },

  inserted_words = {
    filetype = "lua",
    start_lnum = 4,
    prefix = {
      "local columns = {",
      '  "id",',
      '  "email",',
    },
    before = {
      "}",
    },
    after = {
      '  "display_name",',
      "}",
    },
    suffix = {
      "",
      "return columns",
    },
  },

  typst_bold_removal = {
    filetype = "typst",
    start_lnum = 8,
    prefix = {
      '#set math.mat(delim: "[")',
      '#set text(lang: "es")',
      "",
      "= Taller 2.3: Simplex revisado y dualidad",
      "",
      "== Problema 1",
      "$",
    },
    before = {
      '"Minimizar" bold(c)_1 bold(x)_1 + bold(c)_2 bold(x)_2 + bold(c)_3 bold(x)_3 \\',
      '"sujeto a" \\',
      "bold(A)_11 bold(x)_1 + bold(A)_12 bold(x)_2 + bold(A)_13 bold(x)_3 <= bold(b)_1 \\",
      "bold(A)_21 bold(x)_1 + bold(A)_22 bold(x)_2 + bold(A)_23 bold(x)_3 = bold(b)_2 \\",
      "bold(A)_31 bold(x)_1 + bold(A)_32 bold(x)_2 + bold(A)_33 bold(x)_3 >= bold(b)_3 \\",
      'bold(x)_1 <= 0, bold(x)_2 "no restringida", bold(x)_3 >= 0',
    },
    after = {
      '"Minimizar" c_1 x_1 + c_2 x_2 + c_3 x_3 \\',
      '"sujeto a" \\',
      "A_11 x_1 + A_12 x_2 + A_13 x_3 <= b_1 \\",
      "A_21 x_1 + A_22 x_2 + A_23 x_3 = b_2 \\",
      "A_31 x_1 + A_32 x_2 + A_33 x_3 >= b_3 \\",
      'x_1 <= 0, x_2 "no restringida", x_3 >= 0',
    },
    suffix = {
      "$",
      "",
      "*Respuesta:* El problema",
    },
  },
}
