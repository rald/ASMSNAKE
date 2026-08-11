.8086                ; Enforce strict 16-bit 8086 instructions
.model tiny          ; Tiny model combines code/data into one segment for .COM
.code
org 100h             ; COM files must start at memory offset 100h

; -------------------------------------------------------------------------
; CONSTANTS
; -------------------------------------------------------------------------
VGAMODE13     EQU 0013h
TEXTMODE      EQU 0003h
ESC_KEY       EQU 27
MAX_SNAKE_LEN EQU 150
SEG_SIZE      EQU 5   ; Snake segment and food size in pixels
HEADER_HEIGHT EQU 20  ; Reserved top status bar height in pixels

; BIOS Scan Codes for Arrow Keys
KEY_UP        EQU 48h
KEY_DOWN      EQU 50h
KEY_LEFT      EQU 4Bh
KEY_RIGHT     EQU 4Dh

; -------------------------------------------------------------------------
; ENTRY POINT
; -------------------------------------------------------------------------
start:
    cld                ; Ensure direction flag is forward for string operations

    ; 1. Seed the Random Number Generator using BIOS timer ticks
    mov ah, 00h
    int 1ah            ; CX:DX = number of clock ticks since midnight
    push dx            ; Pass low word of timer tick as seed
    call SRand

    ; 2. Initialize Score & Load High Score from HISCORE.TXT
    mov word ptr [score], 0
    call update_score_str
    call load_hiscore

    ; 3. Initialize Snake Position and Length (placed safely below header)
    mov word ptr [snake_len], 3
    mov word ptr [snake_x], 160   ; Head X
    mov word ptr [snake_y], 100   ; Head Y
    mov word ptr [snake_x+2], 155 ; Segment 1 X
    mov word ptr [snake_y+2], 100 ; Segment 1 Y
    mov word ptr [snake_x+4], 150 ; Segment 2 X
    mov word ptr [snake_y+4], 100 ; Segment 2 Y

    ; 4. Spawn first food item safely within playfield
    call spawn_food

    ; 5. Set Mode 13h (320x200, 256 colors)
    mov ax, VGAMODE13
    call SetMode

    ; 6. Load the Sweetie-16 Palette
    call LoadSweetie16

    ; 7. Initial Full Screen Clear (Black background)
    xor ax, ax
    push ax          ; C (Black)
    mov ax, 200
    push ax          ; H
    mov ax, 320
    push ax          ; W
    xor ax, ax       ; Y
    push ax          ; Y
    push ax          ; X
    call FillRect

    ; Draw initial score at top left header (X=5, Y=6, Color 12 - White)
    mov ax, 12
    push ax
    mov ax, 6
    push ax
    mov ax, 5
    push ax
    mov ax, offset score_text
    push ax
    call DrawText

    ; Draw initial high score at top right header (X=215, Y=6, Color 12 - White)
    mov ax, 12
    push ax
    mov ax, 6
    push ax
    mov ax, 215
    push ax
    mov ax, offset hiscore_text
    push ax
    call DrawText

    ; Draw status bar separator line at Y = 19 (Width=320, Height=1, Color=13 - Light Gray)
    mov ax, 13
    push ax
    mov ax, 1
    push ax
    mov ax, 320
    push ax
    mov ax, 19
    push ax
    xor ax, ax
    push ax
    call FillRect

    ; Draw initial food
    mov ax, 3        ; Color 3 (Orange)
    push ax          
    mov ax, SEG_SIZE
    push ax          ; H
    mov ax, SEG_SIZE
    push ax          ; W
    mov ax, [food_y]
    push ax          ; Y
    mov ax, [food_x]
    push ax          ; X
    call FillRect

    ; Draw initial snake segments
    mov cx, [snake_len]
    xor si, si
init_draw_snake:
    mov ax, 5        ; Color 5 (Light Green)
    push ax          
    mov ax, SEG_SIZE
    push ax          ; H
    mov ax, SEG_SIZE
    push ax          ; W
    mov ax, [snake_y + si]
    push ax          ; Y
    mov ax, [snake_x + si]
    push ax          ; X
    call FillRect
    add si, 2
    dec cx
    jnz init_draw_snake

; -------------------------------------------------------------------------
; GAME LOOP
; -------------------------------------------------------------------------
game_loop:
    ; -- A. INPUT --
    mov ah, 01h      ; BIOS check keystroke buffer
    int 16h
    jz short no_input
    jmp process_input

no_input:
    jmp do_tick_check

process_input:
    mov ah, 00h      ; Get the actual keystroke
    int 16h
    
    cmp al, ESC_KEY  ; Check if it was the Escape key
    jne check_key_up
    jmp exit_game

check_key_up:
    cmp ah, KEY_UP
    jne check_key_down
    cmp word ptr [dir_y], SEG_SIZE ; Prevent instant reverse into body
    je short input_done
    mov word ptr [next_dir_x], 0
    mov word ptr [next_dir_y], -SEG_SIZE
    jmp short input_done

check_key_down:
    cmp ah, KEY_DOWN
    jne check_key_left
    cmp word ptr [dir_y], -SEG_SIZE
    je short input_done
    mov word ptr [next_dir_x], 0
    mov word ptr [next_dir_y], SEG_SIZE
    jmp short input_done

check_key_left:
    cmp ah, KEY_LEFT
    jne check_key_right
    cmp word ptr [dir_x], SEG_SIZE
    je short input_done
    mov word ptr [next_dir_x], -SEG_SIZE
    mov word ptr [next_dir_y], 0
    jmp short input_done

check_key_right:
    cmp ah, KEY_RIGHT
    jne short input_done
    cmp word ptr [dir_x], -SEG_SIZE
    je short input_done
    mov word ptr [next_dir_x], SEG_SIZE
    mov word ptr [next_dir_y], 0

input_done:
do_tick_check:
    ; -- B. GAME TICK / MOVEMENT UPDATE --
    dec byte ptr [tick_counter]
    jnz short skip_tick
    jmp do_tick_update

skip_tick:
    jmp render_sync

do_tick_update:
    mov byte ptr [tick_counter], 12  ; Slower speed (moves every 12 frames)

    ; Apply queued direction change
    mov ax, [next_dir_x]
    mov [dir_x], ax
    mov ax, [next_dir_y]
    mov [dir_y], ax

    ; Save current tail coordinates for erasure
    mov bx, [snake_len]
    dec bx
    shl bx, 1
    mov ax, [snake_x + bx]
    mov [old_tail_x], ax
    mov ax, [snake_y + bx]
    mov [old_tail_y], ax

    ; Shift body segments from tail to head
    mov cx, [snake_len]
    dec cx
    jz short update_head
    mov si, cx
    shl si, 1
shift_loop:
    mov ax, [snake_x - 2 + si]
    mov [snake_x + si], ax
    mov ax, [snake_y - 2 + si]
    mov [snake_y + si], ax
    sub si, 2
    jnz short shift_loop

update_head:
    ; Move head position
    mov ax, [snake_x]
    add ax, [dir_x]
    mov [snake_x], ax

    mov ax, [snake_y]
    add ax, [dir_y]
    mov [snake_y], ax

    ; -- C. SCREEN WRAP-AROUND & COLLISION DETECTION --
    ; X-axis boundary wrap check
    mov ax, [snake_x]
    cmp ax, 0
    jge check_right_bound
    mov ax, 320 - SEG_SIZE
    mov [snake_x], ax
    jmp short check_y_bounds
check_right_bound:
    cmp ax, 320
    jl short check_y_bounds
    xor ax, ax
    mov [snake_x], ax

check_y_bounds:
    ; Y-axis boundary wrap check respecting reserved header height
    mov ax, [snake_y]
    cmp ax, HEADER_HEIGHT
    jge check_bottom_bound
    mov ax, 200 - SEG_SIZE
    mov [snake_y], ax
    jmp short check_self_collision
check_bottom_bound:
    cmp ax, 200
    jl short check_self_collision
    mov ax, HEADER_HEIGHT
    mov [snake_y], ax

check_self_collision:
    ; Self collision check (Head vs Body)
    mov cx, [snake_len]
    cmp cx, 1
    jg do_self_checks
    jmp check_food_collision

do_self_checks:
    mov si, 2
self_collision_loop:
    mov ax, [snake_x]
    cmp ax, [snake_x + si]
    jne short next_self_check
    mov ax, [snake_y]
    cmp ax, [snake_y + si]
    je short call_game_over

next_self_check:
    add si, 2
    dec cx
    cmp cx, 1
    jg short self_collision_loop
    jmp short check_food_collision

call_game_over:
    jmp game_over_state

check_food_collision:
    ; Food collision check (Head vs Food)
    mov ax, [snake_x]
    cmp ax, [food_x]
    jne short process_movement_label
    mov ax, [snake_y]
    cmp ax, [food_y]
    je short call_do_grow
    jmp short process_movement_label

call_do_grow:
    jmp do_grow

process_movement_label:
    jmp process_movement

do_grow:
    mov ax, [snake_len]
    cmp ax, MAX_SNAKE_LEN
    jl  grow_allowed
    jmp skip_grow_max

grow_allowed:
    inc word ptr [snake_len]
    
    ; Increment Score & Update string
    inc word ptr [score]
    call update_score_str

    ; Check and update high score
    mov ax, [score]
    cmp ax, [hiscore]
    jg  update_hiscore_block
    jmp skip_new_hiscore

update_hiscore_block:
    mov [hiscore], ax
    call update_hiscore_str
    call save_hiscore

    ; Clear previous high score area background (Width=96, Height=8 at X=215, Y=6)
    mov ax, 0        ; Color 0 (Black)
    push ax
    mov ax, 8        ; Height
    push ax
    mov ax, 96       ; Width (12 chars * 8 pixels)
    push ax
    mov ax, 6        ; Y
    push ax
    mov ax, 215      ; X
    push ax
    call FillRect

    ; Redraw high score at top header
    mov ax, 12
    push ax
    mov ax, 6
    push ax
    mov ax, 215
    push ax
    mov ax, offset hiscore_text
    push ax
    call DrawText
skip_new_hiscore:

    ; Clear previous score area background (Width=80, Height=8 at X=5, Y=6)
    mov ax, 0        ; Color 0 (Black)
    push ax
    mov ax, 8        ; Height
    push ax
    mov ax, 80       ; Width (10 chars * 8 pixels)
    push ax
    mov ax, 6        ; Y
    push ax
    mov ax, 5        ; X
    push ax
    call FillRect

    ; Redraw score at top header
    mov ax, 12
    push ax
    mov ax, 6
    push ax
    mov ax, 5
    push ax
    mov ax, offset score_text
    push ax
    call DrawText

    ; Restore old tail at the newly expanded tail position so tail stays put during growth
    mov bx, [snake_len]
    dec bx
    shl bx, 1
    mov ax, [old_tail_x]
    mov [snake_x + bx], ax
    mov ax, [old_tail_y]
    mov [snake_y + bx], ax
skip_grow_max:
    call spawn_food

    ; Draw new food
    mov ax, 3
    push ax
    mov ax, SEG_SIZE
    push ax
    mov ax, SEG_SIZE
    push ax
    mov ax, [food_y]
    push ax
    mov ax, [food_x]
    push ax
    call FillRect

    ; Draw new head
    mov ax, 5
    push ax
    mov ax, SEG_SIZE
    push ax
    mov ax, SEG_SIZE
    push ax
    mov ax, [snake_y]
    push ax
    mov ax, [snake_x]
    push ax
    call FillRect

    jmp short render_sync

process_movement:
    ; 1. Erase old tail (Color 0 - Black)
    xor ax, ax
    push ax
    mov ax, SEG_SIZE
    push ax
    mov ax, SEG_SIZE
    push ax
    mov ax, [old_tail_y]
    push ax
    mov ax, [old_tail_x]
    push ax
    call FillRect

    ; 2. Draw new head (Color 5 - Light Green)
    mov ax, 5
    push ax
    mov ax, SEG_SIZE
    push ax
    mov ax, SEG_SIZE
    push ax
    mov ax, [snake_y]
    push ax
    mov ax, [snake_x]
    push ax
    call FillRect

render_sync:
    call VWait
    jmp game_loop

; -------------------------------------------------------------------------
; GAME OVER / PAUSE STATE
; -------------------------------------------------------------------------
game_over_state:
    ; Ensure high score is saved on game over
    call save_hiscore

    ; Display "GAME OVER" at center of screen (X=124, Y=96, Color=12 - White)
    mov ax, 12
    push ax
    mov ax, 96
    push ax
    mov ax, 124
    push ax
    mov ax, offset game_over_text
    push ax
    call DrawText

game_over_wait:
    mov ah, 00h      ; Wait for key press
    int 16h
    cmp al, ESC_KEY  ; Check if Escape key was pressed
    jne short game_over_wait
    jmp exit_game

; -------------------------------------------------------------------------
; EXIT
; -------------------------------------------------------------------------
exit_game:
    call save_hiscore
    mov ax, TEXTMODE
    int 10h
    mov ax, 4C00h
    int 21h

; -------------------------------------------------------------------------
; PROCEDURES: FONT RENDERING
; -------------------------------------------------------------------------

; DrawChar(char, x, y, color)
; Stack parameters: [bp+10]=color, [bp+8]=y, [bp+6]=x, [bp+4]=char
DrawChar proc
    push bp
    mov bp, sp
    push ax
    push bx
    push cx
    push dx
    push si
    push di
    push es

    mov ax, 0A000h
    mov es, ax

    ; Calculate font table offset: index = (char - 32) * 8
    mov ax, [bp+4]
    sub al, 32
    xor ah, ah
    mov si, ax
    mov cl, 3
    shl si, cl         ; Multiply index by 8
    add si, offset font_table

    ; Calculate video memory offset DI = Y*320 + X
    mov ax, [bp+8]     ; Y
    mov dx, ax
    mov ah, al
    xor al, al
    mov cl, 6
    shl dx, cl
    add ax, dx
    add ax, [bp+6]     ; X
    mov di, ax

    mov cx, 8          ; 8 rows per character
row_char_loop:
    lodsb              ; AL = row bitmask from font table (si advances)
    mov bl, al
    push cx
    mov cx, 8          ; 8 columns per row

col_char_loop:
    shl bl, 1
    jnc short skip_pixel
    mov al, byte ptr [bp+10]
    mov byte ptr es:[di], al       ; Plot pixel
skip_pixel:
    inc di                         ; Advance DI horizontally to the next pixel
    dec cx
    jnz short col_char_loop

    pop cx
    sub di, 8                      ; Return DI to the start of the row
    add di, 320                    ; Move down to the next screen row
    dec cx
    jnz short row_char_loop

    pop es
    pop di
    pop si
    pop dx
    pop cx
    pop bx
    pop ax
    pop bp
    ret 8
DrawChar endp

; DrawText(text_ptr, x, y, color)
; Stack parameters: [bp+10]=color, [bp+8]=y, [bp+6]=x, [bp+4]=text_ptr
DrawText proc
    push bp
    mov bp, sp
    push ax
    push bx
    push cx
    push dx
    push si

    mov si, [bp+4]
    mov bx, [bp+6]     ; Current X coordinate

text_loop:
    mov al, [si]
    cmp al, 0
    je short text_done

    xor ah, ah
    push word ptr [bp+10] ; color
    push word ptr [bp+8]  ; Y
    push bx               ; X
    push ax               ; char
    call DrawChar

    add bx, 8             ; Advance X by 8 pixels
    inc si
    jmp short text_loop

text_done:
    pop si
    pop dx
    pop cx
    pop bx
    pop ax
    pop bp
    ret 8
DrawText endp

update_score_str proc
    push ax
    push bx
    push cx
    push dx
    push di

    ; Pre-fill score digits with spaces for clean padding ("SCORE:   0")
    mov byte ptr [score_text + 6], ' '
    mov byte ptr [score_text + 7], ' '
    mov byte ptr [score_text + 8], ' '
    mov byte ptr [score_text + 9], '0'

    mov ax, [score]
    cmp ax, 0
    je short format_done

    mov di, offset score_text + 9
    mov cx, 3

convert_loop:
    xor dx, dx
    mov bx, 10
    div bx
    add dl, '0'
    mov [di], dl
    dec di
    dec cx
    cmp ax, 0
    jne short convert_loop

format_done:
    pop di
    pop dx
    pop cx
    pop bx
    pop ax
    ret
update_score_str endp

update_hiscore_str proc
    push ax
    push bx
    push cx
    push dx
    push di

    ; Pre-fill high score digits with spaces for clean padding ("HISCORE:   0")
    mov byte ptr [hiscore_text + 8], ' '
    mov byte ptr [hiscore_text + 9], ' '
    mov byte ptr [hiscore_text + 10], ' '
    mov byte ptr [hiscore_text + 11], '0'

    mov ax, [hiscore]
    cmp ax, 0
    je short hiscore_format_done

    mov di, offset hiscore_text + 11
    mov cx, 3

hiscore_convert_loop:
    xor dx, dx
    mov bx, 10
    div bx
    add dl, '0'
    mov [di], dl
    dec di
    dec cx
    cmp ax, 0
    jne short hiscore_convert_loop

hiscore_format_done:
    pop di
    pop dx
    pop cx
    pop bx
    pop ax
    ret
update_hiscore_str endp

; -------------------------------------------------------------------------
; FILE I/O PROCEDURES (HISCORE.TXT)
; -------------------------------------------------------------------------

load_hiscore proc
    push ax
    push bx
    push cx
    push dx
    push si
    push di

    ; Open HISCORE.TXT for reading
    mov ah, 3Dh
    mov al, 00h          ; Read-only mode
    mov dx, offset hiscore_filename
    int 21h
    jc short load_default

    mov bx, ax           ; File handle
    mov ah, 3Fh          ; Read from file
    mov cx, 5
    mov dx, offset read_buf
    int 21h
    jc short load_err_close

    mov si, ax           ; Save bytes read
    mov ah, 3Eh          ; Close file
    int 21h

    cmp si, 0
    jle short load_default

    ; Null-terminate read_buf at exact bytes read to avoid trailing garbage
    mov bx, si
    mov byte ptr [read_buf + bx], 0

    ; Parse ASCII string into word value
    mov si, offset read_buf
    xor ax, ax
    xor cx, cx
parse_hiscore_loop:
    mov cl, byte ptr [si]
    cmp cl, '0'
    jl short parse_hiscore_done
    cmp cl, '9'
    jg short parse_hiscore_done
    sub cl, '0'
    mov dx, 10
    mul dx
    add ax, cx
    inc si
    jmp short parse_hiscore_loop

load_err_close:
    mov ah, 3Eh
    int 21h
    jmp short load_default

parse_hiscore_done:
    mov [hiscore], ax
    jmp short load_finish

load_default:
    mov word ptr [hiscore], 0

load_finish:
    call update_hiscore_str
    pop di
    pop si
    pop dx
    pop cx
    pop bx
    pop ax
    ret
load_hiscore endp

save_hiscore proc
    push ax
    push bx
    push cx
    push dx
    push si
    push di

    ; Pre-fill write_buf with zero-padding ('0000') to avoid uninitialized bytes
    mov byte ptr [write_buf + 0], '0'
    mov byte ptr [write_buf + 1], '0'
    mov byte ptr [write_buf + 2], '0'
    mov byte ptr [write_buf + 3], '0'
    mov byte ptr [write_buf + 4], 0

    ; Convert hiscore word to 4-byte ASCII string
    mov ax, [hiscore]
    cmp ax, 0
    je short save_write_file

    mov di, offset write_buf + 3
    mov cx, 4
save_conv_loop:
    xor dx, dx
    mov bx, 10
    div bx
    add dl, '0'
    mov [di], dl
    dec di
    dec cx
    cmp ax, 0
    jne short save_conv_loop

save_write_file:
    ; Create / Overwrite HISCORE.TXT for writing
    mov ah, 3Ch
    xor cx, cx           ; Normal file attributes
    mov dx, offset hiscore_filename
    int 21h
    jc short save_exit

    mov bx, ax           ; File handle
    mov ah, 40h          ; Write to file
    mov cx, 4            ; Write 4 bytes
    mov dx, offset write_buf
    int 21h

    mov ah, 3Eh          ; Close file
    int 21h

save_exit:
    pop di
    pop si
    pop dx
    pop cx
    pop bx
    pop ax
    ret
save_hiscore endp

; -------------------------------------------------------------------------
; GAME PROCEDURES
; -------------------------------------------------------------------------

spawn_food proc
    push ax
    push bx
    push cx
    push dx
    push si

generate_food_loop:
    mov ax, 64       ; 64 * 5 = 320 (X range 0 to 320)
    push ax
    call Rand
    mov bx, SEG_SIZE
    mul bx
    mov [food_x], ax

    mov ax, 36       ; 36 blocks * 5 = 180 pixels (Y range 20 to 200)
    push ax
    call Rand
    mov bx, SEG_SIZE
    mul bx
    add ax, HEADER_HEIGHT ; Offset below status bar header
    mov [food_y], ax

    mov cx, [snake_len]
    xor si, si
check_overlap:
    mov ax, [snake_x + si]
    cmp ax, [food_x]
    jne short next_overlap
    mov ax, [snake_y + si]
    cmp ax, [food_y]
    je generate_food_loop
next_overlap:
    add si, 2
    dec cx
    jnz short check_overlap

    pop si
    pop dx
    pop cx
    pop bx
    pop ax
    ret
spawn_food endp

SetMode proc
    int 10h
    ret
SetMode endp

SRand proc
    push bp
    mov bp, sp
    push ax
    mov ax, [bp+4]
    mov [rand_seed], ax
    pop ax
    pop bp
    ret 2
SRand endp

Rand proc
    push bp
    mov bp, sp
    push bx
    push dx

    mov ax, [rand_seed]
    mov bx, 25173
    mul bx
    add ax, 13849
    mov [rand_seed], ax

    mov bx, [bp+4]
    mul bx
    mov ax, dx

    pop dx
    pop bx
    pop bp
    ret 2
Rand endp

LoadSweetie16 proc
    mov dx, 03C8h
    xor al, al
    out dx, al

    mov dx, 03C9h
    lea si, pal_sweetie16
    mov cx, 48
pal_loop:
    lodsb
    out dx, al
    loop pal_loop
    ret
LoadSweetie16 endp

; Draws a filled rectangle directly to VGA video memory (0A000h).
; Stack parameters: [bp+12]=C, [bp+10]=H, [bp+8]=W, [bp+6]=Y, [bp+4]=X
FillRect proc
    push bp
    mov bp, sp
    push es
    push di
    push ax
    push cx
    push dx

    mov ax, 0A000h
    mov es, ax

    mov ax, [bp+6]     ; Y
    mov dx, ax
    mov ah, al
    xor al, al
    mov cl, 6
    shl dx, cl
    add ax, dx
    add ax, [bp+4]     ; X
    mov di, ax

    mov dx, [bp+10]    ; Height
    mov al, [bp+12]    ; Color
    mov ah, al

row_loop:
    mov cx, [bp+8]     ; Width
    shr cx, 1
    push di

    rep stosw

    jnc short skip_odd
    stosb
skip_odd:
    pop di
    add di, 320
    dec dx
    jnz short row_loop

    pop dx
    pop cx
    pop ax
    pop di
    pop es
    pop bp
    ret 10
FillRect endp

VWait proc
    push dx
    push ax
    mov dx, 03DAh
vert_wait:
    in al, dx
    test al, 08h
    jz short vert_wait
    pop ax
    pop dx
    ret
VWait endp

; -------------------------------------------------------------------------
; DATA & FONT TABLE
; -------------------------------------------------------------------------
    rand_seed       dw 1
    score           dw 0
    hiscore         dw 0
    score_text      db "SCORE:   0", 0
    hiscore_text    db "HISCORE:   0", 0
    game_over_text  db "GAME OVER", 0
    
    hiscore_filename db "HISCORE.TXT", 0
    read_buf        db 6 dup(0)
    write_buf       db 6 dup(0)
    
    snake_len       dw 3
    snake_x         dw MAX_SNAKE_LEN dup(0)
    snake_y         dw MAX_SNAKE_LEN dup(0)
    
    dir_x           dw SEG_SIZE   ; Start moving right
    dir_y           dw 0
    next_dir_x      dw SEG_SIZE
    next_dir_y      dw 0
    
    food_x          dw 0
    food_y          dw 0
    
    old_tail_x      dw 0
    old_tail_y      dw 0
    
    tick_counter    db 12

    ; 8x8 Pixel Font Table (ASCII 32 ' ' to 90 'Z')
    font_table:
        ; 32: ' '
        db 0,0,0,0,0,0,0,0
        ; 33-47: Symbols (placeholders)
        REPT 15
        db 0,0,0,0,0,0,0,0
        ENDM
        ; 48: '0' (Fixed clean outline)
        db 3Ch,66h,66h,66h,66h,66h,3Ch,0
        ; 49: '1'
        db 18h,38h,18h,18h,18h,18h,7Eh,0
        ; 50: '2'
        db 3Ch,66h,0Ch,18h,30h,60h,7Eh,0
        ; 51: '3'
        db 3Ch,66h,0Ch,1Ch,0Ch,66h,3Ch,0
        ; 52: '4'
        db 0Ch,1Ch,2Ch,4Ch,7Eh,0Ch,0Ch,0
        ; 53: '5'
        db 7Eh,60h,7Ch,06h,06h,66h,3Ch,0
        ; 54: '6'
        db 1Ch,30h,60h,7Ch,66h,66h,3Ch,0
        ; 55: '7'
        db 7Eh,66h,0Ch,18h,18h,18h,18h,0
        ; 56: '8'
        db 3Ch,66h,66h,3Ch,66h,66h,3Ch,0
        ; 57: '9'
        db 3Ch,66h,66h,3Eh,06h,0Ch,38h,0
        ; 58: ':'
        db 0,18h,18h,0,0,18h,18h,0
        ; 59-64: Symbols (placeholders)
        REPT 6
        db 0,0,0,0,0,0,0,0
        ENDM
        ; 65: 'A'
        db 18h,3Ch,66h,66h,7Eh,66h,66h,0
        ; 66: 'B'
        db 7Ch,66h,66h,7Ch,66h,66h,7Ch,0
        ; 67: 'C'
        db 3Ch,66h,60h,60h,60h,66h,3Ch,0
        ; 68: 'D'
        db 78h,6Ch,66h,66h,66h,6Ch,78h,0
        ; 69: 'E'
        db 7Eh,60h,60h,7Ch,60h,60h,7Eh,0
        ; 70: 'F'
        db 7Eh,60h,60h,7Ch,60h,60h,60h,0
        ; 71: 'G'
        db 3Ch,66h,60h,6Eh,66h,66h,3Ch,0
        ; 72: 'H'
        db 66h,66h,66h,7Eh,66h,66h,66h,0
        ; 73: 'I'
        db 3Ch,18h,18h,18h,18h,18h,3Ch,0
        ; 74: 'J'
        db 1Eh,0Ch,0Ch,0Ch,0Ch,6Ch,38h,0
        ; 75: 'K'
        db 66h,6Ch,78h,70h,78h,6Ch,66h,0
        ; 76: 'L'
        db 60h,60h,60h,60h,60h,60h,7Eh,0
        ; 77: 'M'
        db 63h,77h,7Fh,6Bh,63h,63h,63h,0
        ; 78: 'N'
        db 66h,76h,7Eh,7Eh,6Eh,66h,66h,0
        ; 79: 'O'
        db 3Ch,66h,66h,66h,66h,66h,3Ch,0
        ; 80: 'P'
        db 7Ch,66h,66h,7Ch,60h,60h,60h,0
        ; 81: 'Q'
        db 3Ch,66h,66h,66h,6Ah,3Ch,06h,0
        ; 82: 'R'
        db 7Ch,66h,66h,7Ch,6Ch,66h,66h,0
        ; 83: 'S'
        db 3Ch,60h,3Ch,06h,06h,66h,3Ch,0
        ; 84: 'T'
        db 7Eh,18h,18h,18h,18h,18h,18h,0
        ; 85: 'U'
        db 66h,66h,66h,66h,66h,66h,3Ch,0
        ; 86: 'V'
        db 66h,66h,66h,66h,66h,3Ch,18h,0
        ; 87: 'W'
        db 63h,63h,63h,6Bh,7Fh,77h,63h,0
        ; 88: 'X'
        db 66h,66h,3Ch,18h,3Ch,66h,66h,0
        ; 89: 'Y'
        db 66h,66h,66h,3Ch,18h,18h,18h,0
        ; 90: 'Z'
        db 7Eh,06h,0Ch,18h,30h,60h,7Eh,0

    pal_sweetie16 label byte
        db 6,7,11      ; 0: Dark Blue/Black
        db 23,9,23     ; 1: Purple
        db 44,15,20    ; 2: Red
        db 59,31,21    ; 3: Orange
        db 63,51,29    ; 4: Yellow
        db 41,60,28    ; 5: Light Green
        db 14,45,25    ; 6: Medium Green
        db 9,28,30     ; 7: Dark Green/Teal
        db 10,13,27    ; 8: Dark Blue
        db 14,23,50    ; 9: Blue
        db 16,41,61    ; 10: Light Blue
        db 28,59,61    ; 11: Cyan
        db 61,61,61    ; 12: White
        db 37,44,48    ; 13: Light Gray
        db 21,27,33    ; 14: Medium Gray
        db 12,15,21    ; 15: Dark Gray

end start