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

; BIOS Scan Codes for Arrow Keys
KEY_UP    EQU 48h
KEY_DOWN  EQU 50h
KEY_LEFT  EQU 4Bh
KEY_RIGHT EQU 4Dh

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

    ; 3. Seed the Random Number Generator using BIOS timer ticks
    mov ah, 00h
    int 1ah            ; CX:DX = number of clock ticks since midnight
    push dx            ; Pass low word of timer tick as seed
    call SRand

    ; 4. Generate random initial box location within safe boundaries
    ; Box size is 20x20. Screen is 320x200.
    ; Max X = 320 - 20 = 300 (Rand(301) gives 0 to 300)
    mov ax, 301
    push ax
    call Rand
    mov [box_x], ax

    ; Max Y = 200 - 20 = 180 (Rand(181) gives 0 to 180)
    mov ax, 181
    push ax
    call Rand
    mov [box_y], ax

    ; 5. Set Mode 13h (320x200, 256 colors)
    mov ax, VGAMODE13
    call SetMode

    ; 6. Load the Sweetie-16 Palette
    call LoadSweetie16

; -------------------------------------------------------------------------
; GAME LOOP
; -------------------------------------------------------------------------
game_loop:
    ; -- A. INPUT --
    mov ah, 01h      ; BIOS check keystroke buffer
    int 16h
    jnz check_key    ; If key is available, process it
    jmp near ptr render  ; Otherwise use a safe near jump to render

check_key:
    mov ah, 00h      ; Get the actual keystroke
    int 16h
    
    cmp al, ESC_KEY  ; Check if it was the Escape key
    jne not_esc
    jmp near ptr exit_game     ; Safe near jump to exit
not_esc:

    cmp ah, KEY_UP   ; Check Up Arrow
    je move_up
    cmp ah, KEY_DOWN ; Check Down Arrow
    je move_down
    cmp ah, KEY_LEFT ; Check Left Arrow
    je move_left
    cmp ah, KEY_RIGHT; Check Right Arrow
    je move_right
    jmp near ptr render       ; Unrecognized key, skip movement

move_up:
    mov ax, [box_y]
    sub ax, 4        ; Move up by 4 pixels
    js render        ; Prevent going off-screen (if negative, skip)
    mov [box_y], ax
    jmp render

move_down:
    mov ax, [box_y]
    add ax, 4        ; Move down by 4 pixels
    cmp ax, 180      ; Bottom boundary (200 - 20 box height)
    jg render        ; Prevent going off-screen
    mov [box_y], ax
    jmp render

move_left:
    mov ax, [box_x]
    sub ax, 4        ; Move left by 4 pixels
    js render        ; Prevent going off-screen (if negative, skip)
    mov [box_x], ax
    jmp render

move_right:
    mov ax, [box_x]
    add ax, 4        ; Move right by 4 pixels
    cmp ax, 300      ; Right boundary (320 - 20 box width)
    jg render        ; Prevent going off-screen
    mov [box_x], ax

render:
    ; -- B. RENDER (To Back Buffer) --
    
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

    ; 2. Draw the box at its coordinates (Yellow - Index 4)
    mov ax, 4
    push ax          ; C
    mov ax, 20
    push ax          ; H
    push ax          ; W (Also 20)
    mov ax, [box_y]
    push ax          ; Y
    mov ax, [box_x]
    push ax          ; X
    call FillRect

    ; 3. Copy the Back Buffer to the VGA Screen
    call FlipBuffer

    ; -- C. DELAY --
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

; Sets the video mode. Expects mode number in AX.
SetMode proc
    int 10h
    ret
SetMode endp

; Seeds the Pseudo-Random Number Generator.
; Stack parameters: [bp+4] = seed value (word)
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

; Returns a pseudo-random number from 0 to number-1.
; Stack parameters: [bp+4] = upper bound number (exclusive)
; Returns: AX = random number in range [0, number-1]
Rand proc
    push bp
    mov bp, sp
    push bx
    push dx

    ; 16-bit Linear Congruential Generator update: seed = seed * 25173 + 13849
    mov ax, [rand_seed]
    mov bx, 25173
    mul bx
    add ax, 13849
    mov [rand_seed], ax

    ; Scale to range [0, number-1] using high-word multiplication trick: (seed * number) / 65536
    mov bx, [bp+4]     ; number
    mul bx             ; DX:AX = rand_seed * number
    mov ax, dx         ; AX = high word (scaled random value)

    pop dx
    pop bx
    pop bp
    ret 2
Rand endp

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

    ; FAST MATH: (Y * 320) + X 
    mov ax, [bp+6]     ; Load Y
    mov dx, ax         ; Copy Y to DX
    mov ah, al         ; Multiply AX by 256
    xor al, al         
    
    mov cl, 6
    shl dx, cl         ; DX = Y * 64
    
    add ax, dx         ; AX = Y * 320
    add ax, [bp+4]     ; AX = (Y * 320) + X
    mov di, ax         ; ES:DI points to starting pixel

    mov dx, [bp+10]    ; DX = Height
    mov al, [bp+12]    ; AL = Color Index
    mov ah, al         ; Duplicate color into AH for word writes

row_loop:
    mov cx, [bp+8]     ; CX = Width
    shr cx, 1          ; Divide Width by 2 for word writes
    push di            

    rep stosw          ; Write 2 pixels per cycle

    jnc skip_odd       
    stosb              
skip_odd:
    pop di             
    add di, 320        
    dec dx             
    jnz row_loop       

    pop dx
    pop cx
    pop ax
    pop di
    pop es
    pop bp
    ret 10             
FillRect endp

; Instantly copies the 64,000-byte Back Buffer to the VGA Video Memory
FlipBuffer proc
    push ds
    push es
    push si
    push di
    push cx
    push ax

    mov ax, [cs:buffer_seg]
    mov ds, ax
    xor si, si         

    mov ax, 0A000h
    mov es, ax
    xor di, di         

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

    mov ax, [bp+4]     
    mov bx, 1000
    mul bx             

    mov cx, dx         
    mov dx, ax         
    
    mov ah, 86h        
    int 15h

    pop dx
    pop cx
    pop bx
    pop ax
    pop bp
    ret 2              
Delay endp

; -------------------------------------------------------------------------
; DATA
; -------------------------------------------------------------------------
    buffer_seg      dw 0    ; Stores the dynamically allocated RAM segment
    box_x           dw 0    ; Starting X position (randomized at startup)
    box_y           dw 0    ; Starting Y position (randomized at startup)
    rand_seed       dw 1    ; PRNG seed variable

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