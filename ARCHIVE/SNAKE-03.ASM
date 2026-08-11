.8086                ; Enforce strict 16-bit 8086 instructions
.model tiny          ; Tiny model combines code/data into one segment for .COM
.code
org 100h             ; COM files must start at memory offset 100h

; -------------------------------------------------------------------------
; CONSTANTS
; -------------------------------------------------------------------------
VGAMODE13 EQU 0013h
TEXTMODE  EQU 0003h
ESC_KEY   EQU 27

; -------------------------------------------------------------------------
; ENTRY POINT
; -------------------------------------------------------------------------
start:
    ; 1. Free up unused memory so we can allocate our double buffer
    mov sp, 0FFFEh   ; Ensure stack is safely at the top of our 64KB segment
    mov ah, 4Ah      ; DOS: Modify memory allocation
    mov bx, 1000h    ; Keep 4096 paragraphs (64KB) for this .COM file
    int 21h

    ; 2. Allocate the Back Buffer (64,000 bytes)
    mov ah, 48h      ; DOS: Allocate memory
    mov bx, 0FA0h    ; 4000 paragraphs = 64,000 bytes (320 * 200)
    int 21h
    mov [buffer_seg], ax ; Save the segment address returned by DOS

    ; 3. Set Mode 13h (320x200, 256 colors)
    mov ax, VGAMODE13
    call SetMode

    ; 4. Load the Sweetie-16 Palette
    call LoadSweetie16

; -------------------------------------------------------------------------
; GAME LOOP
; -------------------------------------------------------------------------
game_loop:
    ; -- A. INPUT --
    mov ah, 01h      ; BIOS check keystroke buffer
    int 16h
    jz update_state  ; If zero flag is set, no key pressed
    
    xor ah, ah       ; Fast equivalent of mov ah, 00h
    int 16h
    cmp al, ESC_KEY  ; Check if it was the Escape key
    je exit_game     ; If yes, break the loop and exit

update_state:
    ; -- B. UPDATE --
    ; Move the box X position
    mov ax, [box_x]
    add ax, [box_dir]
    mov [box_x], ax  ; Save new position

    ; Check bounds to bounce off walls
    cmp ax, 300      ; Right edge (320 total width - 20 box width)
    jge reverse_dir
    cmp ax, 0        ; Left edge
    jle reverse_dir
    jmp render

reverse_dir:
    mov ax, [box_dir]
    neg ax           ; Multiply by -1 to reverse direction
    mov [box_dir], ax

render:
    ; -- C. RENDER (To Back Buffer) --
    
    ; 1. Clear the back buffer (Dark Gray - Index 15)
    mov ax, 15
    push ax          ; C
    mov ax, 200
    push ax          ; H
    mov ax, 320
    push ax          ; W
    xor ax, ax       ; Fast 0
    push ax          ; Y
    push ax          ; X
    call FillRect

    ; 2. Draw the box (Yellow - Index 4)
    mov ax, 4
    push ax          ; C
    mov ax, 20
    push ax          ; H
    push ax          ; W (Also 20)
    mov ax, 90
    push ax          ; Y
    mov ax, [box_x]
    push ax          ; X
    call FillRect

    ; 3. Copy the Back Buffer to the VGA Screen
    call FlipBuffer

    ; -- D. DELAY --
    ; Delay for 16 milliseconds (~60 frames per second)
    mov ax, 16
    push ax
    call Delay

    ; Loop back to the start
    jmp game_loop

; -------------------------------------------------------------------------
; EXIT
; -------------------------------------------------------------------------
exit_game:
    ; Restore normal text mode before exiting
    mov ax, TEXTMODE
    call SetMode

    ; Exit to DOS
    mov ax, 4C00h
    int 21h

; -------------------------------------------------------------------------
; PROCEDURES
; -------------------------------------------------------------------------

; Sets the video mode. Expects the mode number in the AX register.
SetMode proc
    int 10h
    ret
SetMode endp

; Loads the 16-color custom palette into the VGA DAC.
LoadSweetie16 proc
    mov dx, 03C8h
    xor al, al
    out dx, al

    mov dx, 03C9h
    lea si, pal_sweetie16
    mov cx, 48         ; 16 colors * 3 bytes
pal_loop:
    lodsb
    out dx, al
    loop pal_loop
    ret
LoadSweetie16 endp

; Draws a filled rectangle to the Back Buffer memory segment.
; Optimized to use Shift/Add math and 16-bit word writes.
; Stack parameters: [bp+12]=C, [bp+10]=H, [bp+8]=W, [bp+6]=Y, [bp+4]=X
FillRect proc
    push bp
    mov bp, sp
    push es
    push di
    push ax
    push cx
    push dx

    ; Point ES to the Back Buffer segment
    mov ax, [cs:buffer_seg]
    mov es, ax

    ; ---------------------------------------------------------
    ; FAST MATH: (Y * 320) + X 
    ; 320 = 256 + 64. We calculate (Y*256) + (Y*64) using shifts
    ; ---------------------------------------------------------
    mov ax, [bp+6]     ; Load Y
    mov dx, ax         ; Copy Y to DX
    mov ah, al         ; Instantly multiply AX by 256 (shift left 8)
    xor al, al         ; Clear lower byte so AX = Y * 256
    
    mov cl, 6
    shl dx, cl         ; DX = Y * 64
    
    add ax, dx         ; AX = (Y * 256) + (Y * 64) = Y * 320
    add ax, [bp+4]     ; AX = (Y * 320) + X
    mov di, ax         ; ES:DI points to the starting pixel

    mov dx, [bp+10]    ; DX = Height (Row counter)
    
    mov al, [bp+12]    ; AL = Color Index
    mov ah, al         ; Duplicate color into AH so AX = Color|Color
                       ; This allows us to write 2 pixels per instruction!

row_loop:
    mov cx, [bp+8]     ; CX = Width
    shr cx, 1          ; Divide Width by 2 to count words instead of bytes
    push di            ; Save starting position of current row

    rep stosw          ; OPTIMIZATION: Write 2 pixels per cycle

    jnc skip_odd       ; If the carry flag isn't set, width was even.
    stosb              ; If width was odd, write the 1 leftover pixel.
skip_odd:
    pop di             ; Restore starting position
    add di, 320        ; Move DI down to the next row
    dec dx             ; Decrement Height counter
    jnz row_loop       ; If Height > 0, repeat

    pop dx
    pop cx
    pop ax
    pop di
    pop es
    pop bp
    ret 10             ; Clean up 10 bytes (5 parameters * 2 bytes)
FillRect endp

; Instantly copies the 64,000-byte Back Buffer to the VGA Video Memory
FlipBuffer proc
    push ds
    push es
    push si
    push di
    push cx
    push ax

    ; Source: Back Buffer segment
    mov ax, [cs:buffer_seg]
    mov ds, ax
    xor si, si         ; SI = 0 (Start of buffer)

    ; Destination: VGA Video Memory segment
    mov ax, 0A000h
    mov es, ax
    xor di, di         ; DI = 0 (Start of screen)

    ; Copy 32,000 words (64,000 bytes). 'rep movsw' is the fastest copy instruction
    mov cx, 32000
    rep movsw

    pop ax
    pop cx
    pop di
    pop si
    pop es
    pop ds
    ret
FlipBuffer endp

; Delays execution for a specified number of milliseconds.
; Stack parameters: [bp+4]=Milliseconds
Delay proc
    push bp
    mov bp, sp
    push ax
    push bx
    push cx
    push dx

    ; BIOS Wait requires microseconds in CX:DX
    mov ax, [bp+4]     ; Load Milliseconds
    mov bx, 1000
    mul bx             ; DX:AX = Milliseconds * 1000

    mov cx, dx         ; CX = High word of microseconds
    mov dx, ax         ; DX = Low word of microseconds
    
    mov ah, 86h        ; BIOS Wait function
    int 15h

    pop dx
    pop cx
    pop bx
    pop ax
    pop bp
    ret 2              ; Clean up 2 bytes
Delay endp

; -------------------------------------------------------------------------
; DATA
; -------------------------------------------------------------------------
    ; Variables
    buffer_seg dw 0    ; Stores the dynamically allocated RAM segment
    box_x      dw 150  ; Starting X position
    box_dir    dw 2    ; Moving 2 pixels at a time

    ; Palette definition (Sweetie-16)
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