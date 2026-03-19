local M = {}

M.state = nil

local STRING_TYPES = {
  string = true,
  string_literal = true,
  char_literal = true,
  raw_string = true,
  interpreted_string_literal = true,
}

local INNER_DELIM_TYPES = {
  argument_list = true,
  parameter_list = true,
  parenthesized_expression = true,
  array = true,
  table_constructor = true,
  dictionary = true,
  subscript = true,
}

local SKIP_FULL_TYPES = {
  binary_expression = true,
  unary_expression = true,
  expression_list = true,
  expression_statement = true,
  concatenation = true,
}

local MATCHING_DELIMS = {
  ["("] = ")",
  ["["] = "]",
  ["{"] = "}",
  ['"'] = '"',
  ["'"] = "'",
  ["`"] = "`",
}

local function to_selection(sr, sc, er, ec, node, kind)
  return {
    sr = sr,
    sc = sc,
    er = er,
    ec = ec,
    node = node,
    kind = kind,
  }
end

local function same_range(a, b)
  return a and b and a.sr == b.sr and a.sc == b.sc and a.er == b.er and a.ec == b.ec
end

local function equivalent_range(a, b)
  if not a or not b then
    return false
  end
  return a.sr == b.sr
    and a.er == b.er
    and math.abs(a.sc - b.sc) <= 1
    and math.abs(a.ec - b.ec) <= 1
end

local function range_contains(outer, inner)
  if not outer or not inner then
    return false
  end
  if outer.sr > inner.sr or outer.er < inner.er then
    return false
  end
  if outer.sr == inner.sr and outer.sc > inner.sc then
    return false
  end
  if outer.er == inner.er and outer.ec < inner.ec then
    return false
  end
  return true
end

local function compatible_range(a, b)
  return same_range(a, b)
    or equivalent_range(a, b)
    or range_contains(a, b)
    or range_contains(b, a)
end

local function range_size(selection)
  return (selection.er - selection.sr) * 100000 + (selection.ec - selection.sc)
end

local function node_contains(node, row, col)
  if not node then
    return false
  end

  local sr, sc, er, ec = node:range()
  if row < sr or row > er then
    return false
  end
  if row == sr and col < sc then
    return false
  end
  if row == er and col >= ec then
    return false
  end

  return true
end

local function get_node_text(bufnr, node)
  local ok, text = pcall(vim.treesitter.get_node_text, node, bufnr)
  if not ok then
    return nil
  end
  return text
end

local function get_inner_selection(bufnr, node)
  local sr, sc, er, ec = node:range()
  local node_type = node:type()

  if STRING_TYPES[node_type] then
    local text = get_node_text(bufnr, node)
    if not text or text:find("\n", 1, true) or #text < 2 then
      return nil
    end
    local first = text:sub(1, 1)
    local last = text:sub(-1)
    if MATCHING_DELIMS[first] ~= last or ec - sc <= 2 then
      return nil
    end
    return to_selection(sr, sc + 1, er, ec - 1, node, "string_inner")
  end

  if not INNER_DELIM_TYPES[node_type] then
    return nil
  end

  local text = get_node_text(bufnr, node)
  if not text or #text < 2 then
    return nil
  end
  local first = text:sub(1, 1)
  local last = text:sub(-1)
  if MATCHING_DELIMS[first] ~= last then
    return nil
  end
  if sr == er and ec - sc <= 2 then
    return nil
  end

  return to_selection(sr, sc + 1, er, ec - 1, node, "inner")
end

local function get_full_selection(node)
  local sr, sc, er, ec = node:range()
  return to_selection(sr, sc, er, ec, node, "node")
end

local function get_buffer_selection(bufnr)
  local line_count = vim.api.nvim_buf_line_count(bufnr)
  if line_count == 0 then
    return nil
  end
  local last = vim.api.nvim_buf_get_lines(bufnr, line_count - 1, line_count, false)[1] or ""
  return to_selection(0, 0, line_count - 1, #last, nil, "buffer")
end

local function is_named_node(node)
  local ok, named = pcall(function()
    return node:named()
  end)
  return ok and named
end

local function push_unique(selections, selection)
  if not selection then
    return
  end
  if selection.er < selection.sr then
    return
  end
  if selection.er == selection.sr and selection.ec <= selection.sc then
    return
  end
  local last = selections[#selections]
  if last and same_range(last, selection) then
    return
  end
  table.insert(selections, selection)
end

local function push_monotonic(selections, selection)
  push_unique(selections, selection)
  if #selections <= 1 then
    return
  end
  local current = selections[#selections]
  local previous = selections[#selections - 1]
  if not range_contains(current, previous) or range_size(current) <= range_size(previous) then
    table.remove(selections)
  end
end

local function get_ancestor_chain(node)
  local chain = {}
  local current = node
  while current do
    table.insert(chain, current)
    current = current:parent()
  end
  return chain
end

local function build_selections(bufnr, row, col)
  local node = vim.treesitter.get_node({ bufnr = bufnr, pos = { row, col } })
  if not node then
    return {}
  end

  local chain = get_ancestor_chain(node)
  local selections = {}
  local saw_string_inner = false
  local saw_delim_inner = false

  for _, ancestor in ipairs(chain) do
    local node_type = ancestor:type()
    if not saw_string_inner and STRING_TYPES[node_type] and node_contains(ancestor, row, col) then
      push_monotonic(selections, get_inner_selection(bufnr, ancestor))
      saw_string_inner = true
    elseif not saw_delim_inner and INNER_DELIM_TYPES[node_type] and node_contains(ancestor, row, col) then
      push_monotonic(selections, get_inner_selection(bufnr, ancestor))
      saw_delim_inner = true
    end
  end

  if #selections == 0 then
    push_monotonic(selections, get_full_selection(node))
  end

  for _, ancestor in ipairs(chain) do
    local node_type = ancestor:type()
    if is_named_node(ancestor) and not SKIP_FULL_TYPES[node_type] then
      push_monotonic(selections, get_full_selection(ancestor))
    end
  end

  push_monotonic(selections, get_buffer_selection(bufnr))
  return selections
end

local function build_list(selections)
  local head = nil
  local prev = nil

  for index, selection in ipairs(selections) do
    local step = {
      index = index,
      range = selection,
      prev = prev,
      next = nil,
    }

    if prev then
      prev.next = step
    else
      head = step
    end

    prev = step
  end

  return head, prev
end

local function get_visual_selection()
  local start_pos = vim.fn.getpos("'<")
  local end_pos = vim.fn.getpos("'>")
  local sr = start_pos[2] - 1
  local sc = start_pos[3] - 1
  local er = end_pos[2] - 1
  local ec = end_pos[3]

  if sr > er or (sr == er and sc > ec) then
    sr, er = er, sr
    sc, ec = ec, sc
  end

  return to_selection(sr, sc, er, ec, nil, "visual")
end

local function get_probe_position(bufnr, selection)
  local lines = vim.api.nvim_buf_get_lines(bufnr, selection.sr, selection.er + 1, false)

  for offset, line in ipairs(lines) do
    local row = selection.sr + offset - 1
    local start_col = row == selection.sr and selection.sc or 0
    local end_col = row == selection.er and math.min(#line, selection.ec) or #line

    for col = start_col, end_col - 1 do
      local ch = line:sub(col + 1, col + 1)
      if ch ~= " " and ch ~= "\t" then
        return row, col
      end
    end
  end

  return selection.sr, selection.sc
end

local function select_range(selection)
  if not selection then
    return
  end

  local sr = selection.sr
  local sc = selection.sc
  local er = selection.er
  local ec = selection.ec
  local bufnr = vim.api.nvim_get_current_buf()
  local line_count = vim.api.nvim_buf_line_count(bufnr)

  if er >= line_count then
    er = line_count - 1
    local last = vim.api.nvim_buf_get_lines(bufnr, er, er + 1, false)[1] or ""
    ec = #last
  end

  vim.fn.setpos("'<", { 0, sr + 1, sc + 1, 0 })
  vim.fn.setpos("'>", { 0, er + 1, ec, 0 })
  vim.cmd("normal! gv")
end

local function iter_steps(head)
  local step = head
  return function()
    local current = step
    if current then
      step = current.next
    end
    return current
  end
end

local function find_matching_step(head, current)
  local best = nil
  local best_score = math.huge

  for step in iter_steps(head) do
    local range = step.range
    local score = nil

    if same_range(range, current) then
      score = 0
    elseif equivalent_range(range, current) then
      score = 1
    elseif range_contains(range, current) or range_contains(current, range) then
      score = math.abs(range_size(range) - range_size(current)) + 10
    end

    if score and score < best_score then
      best = step
      best_score = score
    end
  end

  return best
end

local function build_state(bufnr, row, col)
  local selections = build_selections(bufnr, row, col)
  local head, tail = build_list(selections)
  return {
    bufnr = bufnr,
    row = row,
    col = col,
    head = head,
    tail = tail,
    current = nil,
  }
end

local function ensure_state_from_normal()
  local bufnr = vim.api.nvim_get_current_buf()
  local cursor = vim.api.nvim_win_get_cursor(0)
  M.state = build_state(bufnr, cursor[1] - 1, cursor[2])
  M.state.current = M.state.head
  return M.state
end

local function ensure_state_from_visual()
  local bufnr = vim.api.nvim_get_current_buf()
  local current = get_visual_selection()
  local row, col = get_probe_position(bufnr, current)

  if not M.state or M.state.bufnr ~= bufnr then
    M.state = build_state(bufnr, row, col)
  end

  if M.state.current and compatible_range(M.state.current.range, current) then
    return M.state
  end

  if M.state.current and M.state.current.next and compatible_range(M.state.current.next.range, current) then
    M.state.current = M.state.current.next
    return M.state
  end

  if M.state.current and M.state.current.prev and compatible_range(M.state.current.prev.range, current) then
    M.state.current = M.state.current.prev
    return M.state
  end

  local step = find_matching_step(M.state.head, current)
  if not step then
    M.state = build_state(bufnr, row, col)
    step = find_matching_step(M.state.head, current) or M.state.head
  end

  M.state.current = step
  return M.state
end

function M.expand()
  local mode = vim.fn.mode()

  if mode == "v" or mode == "V" then
    local state = ensure_state_from_visual()
    if state.current and state.current.next then
      state.current = state.current.next
      select_range(state.current.range)
    elseif state.tail then
      state.current = state.tail
      select_range(state.current.range)
    end
    return
  end

  local state = ensure_state_from_normal()
  if state.current then
    select_range(state.current.range)
  end
end

function M.shrink()
  local mode = vim.fn.mode()
  if mode ~= "v" and mode ~= "V" then
    return
  end

  local state = ensure_state_from_visual()
  if state.current and state.current.prev then
    state.current = state.current.prev
    select_range(state.current.range)
  end
end

function M.clear()
  M.state = nil
end

function M._debug()
  local bufnr = vim.api.nvim_get_current_buf()
  local cursor = vim.api.nvim_win_get_cursor(0)
  local state = build_state(bufnr, cursor[1] - 1, cursor[2])
  local items = {}

  for step in iter_steps(state.head) do
    table.insert(items, {
      index = step.index,
      kind = step.range.kind,
      node_type = step.range.node and step.range.node:type() or nil,
      range = { step.range.sr, step.range.sc, step.range.er, step.range.ec },
    })
  end

  return items
end

function M.setup(opts)
  opts = opts or {}

  local augroup = vim.api.nvim_create_augroup("quickselect_state", { clear = true })

  vim.api.nvim_create_autocmd({ "ModeChanged" }, {
    group = augroup,
    callback = function(args)
      local old_mode, new_mode = args.match:match("([^:]+):(.+)")
      local was_visual = old_mode == "v" or old_mode == "V" or old_mode == "\22"
      local is_visual = new_mode == "v" or new_mode == "V" or new_mode == "\22"
      if was_visual and not is_visual then
        vim.schedule(function()
          local mode = vim.fn.mode()
          if mode ~= "v" and mode ~= "V" and mode ~= "\22" then
            M.clear()
          end
        end)
      end
    end,
  })

  vim.api.nvim_create_autocmd({ "BufLeave", "WinLeave", "InsertEnter", "CmdlineEnter" }, {
    group = augroup,
    callback = function()
      M.clear()
    end,
  })

  if opts.keymap then
    for _, map in ipairs(opts.keymap) do
      vim.keymap.set(map.mode or { "n", "v" }, map.key, map.fn, { desc = map.desc })
    end
  end
end

return M
