module main

import gg
import rand
import time

// Increase Sokol Gfx pool limits globally before headers compile
#flag -DSG_DEFAULT_SAMPLER_POOL_SIZE=256
#flag -DSG_DEFAULT_IMAGE_POOL_SIZE=256

// Default card dimensions (500x726)
const default_card_width  = 500
const default_card_height = 726

// Scale down factor for rendering so 500x726 fits comfortably on screen (e.g. scale factor ~0.16)
const render_scale = 0.16

const card_width  = int(default_card_width * render_scale)
const card_height = int(default_card_height * render_scale)
const card_margin = 25
const start_x     = 40
const start_y     = 100
const cols        = 8

// Calculate window size to closely fit the playing area
const default_width  = (cols * card_width) + ((cols - 1) * card_margin) + (start_x * 2) + card_width + 40
const default_height = (4 * (card_height + card_margin + 35)) + start_y + 60

// Cascading offsets when cards stack in a pile slot
const stack_offset_x = 0
const stack_offset_y = 14

enum Suit {
	hearts
	diamonds
	clubs
	spades
}

struct Card {
mut:
	suit Suit
	rank int // 2-10, 11=J, 12=Q, 13=K
}

// Snapshot for UNDO functionality
struct UndoState {
	deck       []Card
	grid       [][]Card
	move_count int
	is_won     bool
	message    string
}

// Animation data structure for card movement
struct Animation {
	card       Card
	start_x    f32
	start_y    f32
	end_x      f32
	end_y      f32
	start_time i64
	duration   f32 // in milliseconds
	target_r   int
	target_c   int
}

struct App {
mut:
	gg            &gg.Context = unsafe { nil }
	deck          []Card
	grid          [][]Card
	undo_stack    []UndoState
	animations    []Animation
	move_count    int
	is_won        bool
	selected_r    int = -1
	selected_c    int = -1
	message       string = 'Click a card to select, then click a target slot.'
	
	// Card texture assets map: key = "2_of_clubs", value = gg.Image
	card_images   map[string]gg.Image
	card_back_img gg.Image
	has_card_back bool
}

fn main() {
	mut app := &App{}
	app.new_game()

	app.gg = gg.new_context(
		bg_color: gg.rgb(34, 112, 62)
		width: default_width
		height: default_height
		window_title: 'Mod3 Solitaire'
		init_fn: init_app
		frame_fn: frame
		click_fn: on_click
		user_data: app
	)
	app.gg.run()
}

// Convert card rank integer and Suit enum into filename stem
fn card_texture_key(rank int, suit Suit) string {
	suit_str := match suit {
		.hearts   { 'hearts' }
		.diamonds { 'diamonds' }
		.clubs    { 'clubs' }
		.spades   { 'spades' }
	}

	rank_str := match rank {
		11   { 'jack' }
		12   { 'queen' }
		13   { 'king' }
		else { rank.str() }
	}

	return '${rank_str}_of_${suit_str}'
}

// Startup initialization: load card back & face PNG textures once
fn init_app(mut app App) {
	// Load card back image once from PNG-cards-1.3 folder
	if img := app.gg.create_image('PNG-cards-1.3/card_back.png') {
		app.card_back_img = img
		app.has_card_back = true
	} else {
		println('Warning: Could not load card_back.png from PNG-cards-1.3/')
	}

	// Pre-load all face card textures from PNG folder (ranks 2 through 13 across all 4 suits)
	suits := [Suit.hearts, Suit.diamonds, Suit.clubs, Suit.spades]
	for s in suits {
		for r in 2 .. 14 {
			key := card_texture_key(r, s)
			file_path := 'PNG-cards-1.3/${key}.png'
			if img := app.gg.create_image(file_path) {
				app.card_images[key] = img
			} else {
				println('Warning: Could not load texture at ${file_path}')
			}
		}
	}
}

// Initialize 2 decks, remove all Aces, and deal starting board
fn (mut app App) new_game() {
	app.deck.clear()
	app.undo_stack.clear()
	app.animations.clear()
	app.move_count = 0
	app.is_won = false
	app.selected_r = -1
	app.selected_c = -1
	app.message = 'New Game started. Build sequences in rows 1-3!'

	app.grid = [][]Card{cap: 32}
	for _ in 0 .. 32 {
		app.grid << []Card{}
	}

	suits := [Suit.hearts, Suit.diamonds, Suit.clubs, Suit.spades]
	for _ in 0 .. 2 {
		for s in suits {
			for r in 2 .. 14 {
				app.deck << Card{
					suit: s
					rank: r
				}
			}
		}
	}

	rand.shuffle(mut app.deck) or {}

	for i in 0 .. 32 {
		if app.deck.len > 0 {
			card := app.deck.pop()
			app.grid[i] << card
		}
	}
}

// Helper to get current dynamic scale factor based on window dimensions
fn get_scale(ctx &gg.Context) f32 {
	scale_w := f32(ctx.width) / f32(default_width)
	scale_h := f32(ctx.height) / f32(default_height)
	if scale_w < scale_h {
		return scale_w
	}
	return scale_h
}

fn (mut app App) animate_card_move(card Card, start_px f32, start_py f32, target_r int, target_c int, delay_ms f32) {
	scale := get_scale(app.gg)
	card_w := f32(card_width) * scale
	card_h := f32(card_height) * scale
	card_m := f32(card_margin) * scale
	start_x_f := f32(start_x) * scale
	start_y_f := f32(start_y) * scale

	row_y := start_y_f + f32(target_r) * (card_h + card_m + 35.0 * scale)
	base_x := start_x_f + f32(target_c) * (card_w + card_m)
	
	slot_idx := target_r * cols + target_c
	pile_len := app.grid[slot_idx].len - 1

	target_x := base_x + f32(pile_len) * (f32(stack_offset_x) * scale)
	target_y := row_y + f32(pile_len) * (f32(stack_offset_y) * scale)

	now := time.ticks()
	app.animations << Animation{
		card: card
		start_x: start_px
		start_y: start_py
		end_x: target_x
		end_y: target_y
		start_time: now + i64(delay_ms)
		duration: 200.0
		target_r: target_r
		target_c: target_c
	}
}

fn (mut app App) animate_deal_from_talon(card Card, target_r int, target_c int, delay_ms f32) {
	scale := get_scale(app.gg)
	card_w := f32(card_width) * scale
	card_h := f32(card_height) * scale
	card_m := f32(card_margin) * scale
	start_x_f := f32(start_x) * scale
	start_y_f := f32(start_y) * scale

	side_x := start_x_f + f32(cols) * (card_w + card_m) + 20.0 * scale
	talon_y := start_y_f + 3.0 * (card_h + card_m + 35.0 * scale)
	app.animate_card_move(card, side_x, talon_y, target_r, target_c, delay_ms)
}

fn (mut app App) save_undo_state() {
	mut grid_copy := [][]Card{cap: app.grid.len}
	for pile in app.grid {
		grid_copy << pile.clone()
	}

	app.undo_stack << UndoState{
		deck: app.deck.clone()
		grid: grid_copy
		move_count: app.move_count
		is_won: app.is_won
		message: app.message
	}
}

fn (mut app App) undo_last_move() {
	if app.undo_stack.len == 0 {
		app.message = 'Nothing to undo!'
		return
	}

	state := app.undo_stack.pop()
	app.animations.clear()
	app.deck = state.deck.clone()
	app.grid = state.grid.clone()
	app.move_count = state.move_count
	app.is_won = state.is_won
	app.message = 'Undo successful.'
	app.selected_r = -1
	app.selected_c = -1
}

fn frame(mut app App) {
	app.gg.begin()

	win_w := app.gg.width
	win_h := app.gg.height
	scale := get_scale(app.gg)

	card_w := f32(card_width) * scale
	card_h := f32(card_height) * scale
	card_m := f32(card_margin) * scale
	start_x_f := f32(start_x) * scale
	start_y_f := f32(start_y) * scale

	now := time.ticks()

	// Header Area
	app.gg.draw_text(int(start_x_f), int(14.0 * scale), 'MOD3 SOLITAIRE', gg.TextCfg{
		color: gg.white
		size: int(22.0 * scale)
		bold: true
	})

	msg_color := if app.is_won { gg.rgb(100, 255, 100) } else { gg.yellow }
	app.gg.draw_text(int(start_x_f), int(42.0 * scale), app.message, gg.TextCfg{
		color: msg_color
		size: int(13.0 * scale)
		bold: app.is_won
	})

	labels := [
		'Row 1 Target: 2 - 5 - 8 - J',
		'Row 2 Target: 3 - 6 - 9 - Q',
		'Row 3 Target: 4 - 7 - 10 - K',
		'Row 4: Waste / Free Slots'
	]

	// Render Grid (4 Rows x 8 Columns)
	for r in 0 .. 4 {
		row_y := start_y_f + f32(r) * (card_h + card_m + 35.0 * scale)

		app.gg.draw_text(int(start_x_f), int(row_y - 15.0 * scale), labels[r], gg.TextCfg{
			color: gg.rgb(210, 240, 210)
			size: int(11.0 * scale)
			bold: true
		})

		for c in 0 .. cols {
			base_x := start_x_f + f32(c) * (card_w + card_m)
			slot_idx := r * cols + c

			// Base Slot Outline
			app.gg.draw_rect_empty(base_x, row_y, card_w, card_h, gg.rgba(255, 255, 255, 70))

			pile := app.grid[slot_idx]
			for i in 0 .. pile.len {
				is_top := (i == pile.len - 1)
				mut is_animating := false
				if is_top {
					for anim in app.animations {
						if anim.target_r == r && anim.target_c == c && now >= anim.start_time {
							is_animating = true
							break
						}
					}
				}

				if !is_animating {
					card := pile[i]
					is_selected := is_top && (r == app.selected_r && c == app.selected_c)

					cx := base_x + f32(i) * (f32(stack_offset_x) * scale)
					cy := row_y + f32(i) * (f32(stack_offset_y) * scale)

					draw_card(mut app, int(cx), int(cy), card_w, card_h, card, is_selected)
				}
			}
		}
	}

	side_x := start_x_f + f32(cols) * (card_w + card_m) + 20.0 * scale

	// Restart Button
	restart_y := start_y_f
	btn_h := 35.0 * scale
	app.gg.draw_rect_filled(side_x, restart_y, card_w, btn_h, gg.rgb(190, 50, 50))
	app.gg.draw_rect_empty(side_x, restart_y, card_w, btn_h, gg.white)
	app.gg.draw_text(int(side_x + 6.0 * scale), int(restart_y + 10.0 * scale), 'NEW GAME', gg.TextCfg{ color: gg.white, size: int(10.0 * scale), bold: true })

	// Undo Button
	undo_y := restart_y + 45.0 * scale
	undo_btn_color := if app.undo_stack.len > 0 { gg.rgb(60, 140, 200) } else { gg.rgb(70, 70, 70) }
	app.gg.draw_rect_filled(side_x, undo_y, card_w, btn_h, undo_btn_color)
	app.gg.draw_rect_empty(side_x, undo_y, card_w, btn_h, gg.white)
	app.gg.draw_text(int(side_x + 14.0 * scale), int(undo_y + 10.0 * scale), 'UNDO', gg.TextCfg{ color: gg.white, size: int(10.0 * scale), bold: true })

	// Talon Deck
	talon_y := start_y_f + 3.0 * (card_h + card_m + 35.0 * scale)
	if app.deck.len > 0 {
		if app.has_card_back {
			app.gg.draw_image(side_x, talon_y, card_w, card_h, &app.card_back_img)
			app.gg.draw_rect_empty(side_x, talon_y, card_w, card_h, gg.black)
		} else {
			draw_procedural_card_back(app.gg, int(side_x), int(talon_y), int(card_w), int(card_h))
		}
	} else {
		app.gg.draw_rect_empty(side_x, talon_y, card_w, card_h, gg.rgba(255, 255, 255, 70))
	}

	// Render Active Animations
	mut active_anims := []Animation{}
	for anim in app.animations {
		if now < anim.start_time {
			active_anims << anim
			continue
		}

		elapsed := f32(now - anim.start_time)
		progress := elapsed / anim.duration

		if progress < 1.0 {
			cur_x := anim.start_x + (anim.end_x - anim.start_x) * progress
			cur_y := anim.start_y + (anim.end_y - anim.start_y) * progress

			draw_card(mut app, int(cur_x), int(cur_y), card_w, card_h, anim.card, false)
			active_anims << anim
		}
	}
	app.animations = active_anims.clone()

	// Victory Banner
	if app.is_won {
		banner_w := 400.0 * scale
		banner_h := 100.0 * scale
		bx := f32(win_w / 2) - (banner_w / 2)
		by := f32(win_h / 2) - (banner_h / 2)

		app.gg.draw_rect_filled(bx, by, banner_w, banner_h, gg.rgba(0, 0, 0, 210))
		app.gg.draw_rect_empty(bx, by, banner_w, banner_h, gg.rgb(255, 215, 0))

		app.gg.draw_text(int(bx + 40.0 * scale), int(by + 20.0 * scale), 'CONGRATULATIONS! YOU WON!', gg.TextCfg{
			color: gg.yellow
			size: int(18.0 * scale)
			bold: true
		})
		app.gg.draw_text(int(bx + 90.0 * scale), int(by + 55.0 * scale), 'Completed in ${app.move_count} moves.', gg.TextCfg{
			color: gg.white
			size: int(13.0 * scale)
		})
	}

	// Bottom Bar
	bar_h := 30.0 * scale
	bar_y := f32(win_h) - bar_h
	app.gg.draw_rect_filled(0, bar_y, f32(win_w), bar_h, gg.rgb(20, 70, 38))
	app.gg.draw_rect_empty(0, bar_y, f32(win_w), bar_h, gg.rgba(255, 255, 255, 50))

	moves_right_x := f32(win_w) - 120.0 * scale
	app.gg.draw_text(int(moves_right_x), int(bar_y + 7.0 * scale), 'MOVES: ${app.move_count}', gg.TextCfg{
		color: gg.white
		size: int(12.0 * scale)
		bold: true
	})

	app.gg.end()
}

fn draw_procedural_card_back(ctx &gg.Context, x int, y int, w int, h int) {
	ctx.draw_rect_filled(f32(x), f32(y), f32(w), f32(h), gg.white)
	ctx.draw_rect_empty(f32(x), f32(y), f32(w), f32(h), gg.black)

	ix := f32(x + 4)
	iy := f32(y + 4)
	iw := f32(w - 8)
	ih := f32(h - 8)

	ctx.draw_rect_filled(ix, iy, iw, ih, gg.rgb(25, 60, 150))
	
	pattern_color := gg.rgba(255, 255, 255, 80)
	for offset in 0 .. 12 {
		step := offset * 8
		if step < int(ih) {
			ctx.draw_line(ix, iy + f32(step), ix + f32(step), iy, pattern_color)
			ctx.draw_line(ix + iw - f32(step), iy + ih, ix + iw, iy + ih - f32(step), pattern_color)
		}
	}
}

// Render card using PNG face texture with scalable width/height
fn draw_card(mut app App, x int, y int, w f32, h f32, card Card, selected bool) {
	key := card_texture_key(card.rank, card.suit)

	if img := app.card_images[key] {
		app.gg.draw_image(f32(x), f32(y), w, h, &img)
	} else {
		app.gg.draw_rect_filled(f32(x), f32(y), w, h, gg.white)
	}

	if selected {
		app.gg.draw_rect_empty(f32(x), f32(y), w, h, gg.rgb(255, 140, 0))
		app.gg.draw_rect_empty(f32(x + 1), f32(y + 1), w - 2.0, h - 2.0, gg.rgb(255, 200, 0))
	} else {
		app.gg.draw_rect_empty(f32(x), f32(y), w, h, gg.black)
	}
}

fn on_click(x f32, y f32, button gg.MouseButton, mut app App) {
	if button != .left {
		return
	}

	scale := get_scale(app.gg)
	card_w := f32(card_width) * scale
	card_h := f32(card_height) * scale
	card_m := f32(card_margin) * scale
	start_x_f := f32(start_x) * scale
	start_y_f := f32(start_y) * scale

	side_x := start_x_f + f32(cols) * (card_w + card_m) + 20.0 * scale

	// 1. Click New Game Button
	restart_y := start_y_f
	btn_h := 35.0 * scale
	if x >= side_x && x <= side_x + card_w && y >= restart_y && y <= restart_y + btn_h {
		app.new_game()
		return
	}

	// 2. Click Undo Button
	undo_y := restart_y + 45.0 * scale
	if x >= side_x && x <= side_x + card_w && y >= undo_y && y <= undo_y + btn_h {
		app.undo_last_move()
		return
	}

	// 3. Click Talon
	talon_y := start_y_f + 3.0 * (card_h + card_m + 35.0 * scale)
	if x >= side_x && x <= side_x + card_w && y >= talon_y && y <= talon_y + card_h {
		app.deal_from_talon()
		return
	}

	// 4. Click Grid Cards
	for r in 0 .. 4 {
		row_y := start_y_f + f32(r) * (card_h + card_m + 35.0 * scale)

		for c in 0 .. cols {
			gx_pos := start_x_f + f32(c) * (card_w + card_m)
			slot_idx := r * cols + c
			pile_len := app.grid[slot_idx].len

			stack_w := card_w
			stack_h := card_h + if pile_len > 1 { f32(pile_len - 1) * (f32(stack_offset_y) * scale) } else { 0.0 }

			if x >= gx_pos && x <= gx_pos + stack_w && y >= row_y && y <= row_y + stack_h {
				app.handle_grid_click(r, c)
				return
			}
		}
	}
}

fn (mut app App) handle_grid_click(r int, c int) {
	slot_idx := r * cols + c

	if app.selected_r == -1 {
		if app.grid[slot_idx].len > 0 {
			app.selected_r = r
			app.selected_c = c
			card := app.grid[slot_idx].last()
			app.message = 'Selected: ${card.rank} of ${card.suit}'
		}
		return
	}

	if app.selected_r == r && app.selected_c == c {
		app.selected_r = -1
		app.selected_c = -1
		app.message = 'Selection cleared.'
		return
	}

	from_r := app.selected_r
	from_c := app.selected_c
	from_idx := from_r * cols + from_c
	card := app.grid[from_idx].last()

	if app.is_valid_move(card, r, c) {
		app.save_undo_state()

		scale := get_scale(app.gg)
		card_w := f32(card_width) * scale
		card_h := f32(card_height) * scale
		card_m := f32(card_margin) * scale
		start_x_f := f32(start_x) * scale
		start_y_f := f32(start_y) * scale

		start_px := start_x_f + f32(from_c) * (card_w + card_m)
		from_pile_len := app.grid[from_idx].len - 1
		start_py := start_y_f + f32(from_r) * (card_h + card_m + 35.0 * scale) + (f32(from_pile_len) * (f32(stack_offset_y) * scale))

		moved_card := app.grid[from_idx].pop()
		app.grid[slot_idx] << moved_card
		app.move_count++
		app.message = 'Moved card successfully.'

		app.animate_card_move(moved_card, start_px, start_py, r, c, 0)
		app.fill_empty_row4_slots()
		app.check_win_condition()
	} else {
		app.message = 'Invalid move according to Mod3-style sequence rules!'
	}

	app.selected_r = -1
	app.selected_c = -1
}

fn (mut app App) fill_empty_row4_slots() {
	mut delay_offset := f32(0.0)
	for c in 0 .. cols {
		slot_idx := 3 * cols + c
		if app.grid[slot_idx].len == 0 && app.deck.len > 0 {
			card := app.deck.pop()
			app.grid[slot_idx] << card
			
			app.animate_deal_from_talon(card, 3, c, delay_offset)
			delay_offset += 60.0

			app.message += ' Auto-filled Row 4 slot from Talon.'
		}
	}
}

fn (mut app App) check_win_condition() {
	if app.deck.len > 0 {
		return
	}

	for c in 0 .. cols {
		slot_idx := 3 * cols + c
		if app.grid[slot_idx].len > 0 {
			return
		}
	}

	for r in 0 .. 3 {
		for c in 0 .. cols {
			slot_idx := r * cols + c
			if app.grid[slot_idx].len != 4 {
				return
			}
		}
	}

	app.is_won = true
	app.message = 'YOU WIN! All target sequences are complete!'
}

fn (app App) is_valid_move(card Card, to_r int, to_c int) bool {
	dest_idx := to_r * cols + to_c
	dest_pile := app.grid[dest_idx]

	if to_r == 3 {
		return dest_pile.len == 0
	}

	if dest_pile.len >= 4 {
		return false
	}

	expected_rank := 2 + to_r + (dest_pile.len * 3)

	if card.rank != expected_rank {
		return false
	}

	if dest_pile.len > 0 {
		top_card := dest_pile.last()
		if top_card.suit != card.suit {
			return false
		}
	}

	return true
}

fn (mut app App) deal_from_talon() {
	if app.deck.len == 0 {
		app.message = 'Talon is empty!'
		return
	}

	app.save_undo_state()

	mut dealt := 0
	mut delay_offset := f32(0.0)

	for c in 0 .. cols {
		if app.deck.len > 0 {
			slot_idx := 3 * cols + c
			card := app.deck.pop()
			app.grid[slot_idx] << card

			app.animate_deal_from_talon(card, 3, c, delay_offset)
			delay_offset += 50.0

			dealt++
		}
	}

	app.message = 'Dealt ${dealt} card(s) across Row 4 slots.'
	app.check_win_condition()
}

