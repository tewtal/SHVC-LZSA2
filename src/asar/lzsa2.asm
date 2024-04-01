; SHVC-LZSA2
; David Lindecrantz <optiroc@me.com>
;
; Bugfixes and conversion to ASAR by <total@viskos.org>
;
; LZSA2 decompressor

; TODO
; - Try source offset always in 16-bit x, dest in Y; minimize accumulator width toggling
; - Check bank if mvn jump can be short
; - Option to inline nibble access

; LZSA2_opt_dma_scratchpad
; - Document speed diff

; LZSA2_OPT_DMA_SCRATCHPAD
; Use SNES DMA registers at $4370-$4377 as scratchpad for MVN instructions.
;
; 0 - Do not use DMA registers as scratchpad (direct page usage = $12 bytes)
; 1 - Use DMA registers as scratchpad (no direct page usage)

!Scratchpad = $39
!LZSA2_OPT_DMA_SCRATCHPAD = 0 ; Use DMA registers as scratchpad for MVN instructions


; Scratchpad
if !LZSA2_OPT_DMA_SCRATCHPAD = 1
    LZSA2_token            = $804340 ; Current token
    LZSA2_nibble           = $804341 ; Current nibble
    LZSA2_nibrdy           = $804342 ; Nibble ready
    LZSA2_match            = $804343 ; Previous match offset
    LZSA2_source           = $804345 ; Source (indirect long)
    LZSA2_dest             = $804348 ; Destination (indirect long)
    LZSA2_mvl              = $804350 ; Literal block move (mvn + banks + return)
    LZSA2_mvm              = $804354 ; Match block move (mvn + banks + return)
else
    LZSA2_token            = !Scratchpad+$00 ; Current token
    LZSA2_nibble           = !Scratchpad+$01 ; Current nibble
    LZSA2_nibrdy           = !Scratchpad+$02 ; Nibble ready
    LZSA2_match            = !Scratchpad+$05 ; Previous match offset
    LZSA2_source           = !Scratchpad+$07 ; Source (indirect long)
    LZSA2_dest             = !Scratchpad+$0a ; Destination (indirect long)
    LZSA2_mvl              = !Scratchpad+$0d ; Literal block move (mvn + banks + return)
    LZSA2_mvm              = !Scratchpad+$11 ; Match block move (mvn + banks + return)
endif

; Decompress LZSA2 block
;
; Parameters (a8i16):
;   x           Source offset
;   y           Destination offset
;   b:a         Destination:Source banks
; Returns (a8i16):
;   x           Decompressed length
LZSA2_DecompressBlock:
Setup:
if !LZSA2_OPT_DMA_SCRATCHPAD = 1
    phd
    rep #$20
    pha
    lda #$4300              ; Set direct page at CPU MMIO area
    tcd
    pla
endif

    sep #$20
    phy                     ; Push destination offset for decompressed length calculation

    stz.b LZSA2_nibrdy
    stx.b LZSA2_source+$00   ; Write source for indirect and block move addressing
    sta.b LZSA2_source+$02
    sta.b LZSA2_mvl+$02

    xba                     ; Write destination for indirect and block move addressing
    sty.b LZSA2_dest+$00
    sta.b LZSA2_dest+$02
    sta.b LZSA2_mvl+$01
    sta.b LZSA2_mvm+$01
    sta.b LZSA2_mvm+$02

    lda.b #$54                ; Write MVN and return instructions
    sta.b LZSA2_mvl+$00
    sta.b LZSA2_mvm+$00
    lda.b #$6b                ; $60 = RTS, $6b = RTL
    sta.b LZSA2_mvl+$03
    sta.b LZSA2_mvm+$03

ReadToken:
    lda.b [LZSA2_source]     ; Read token byte
    sta.b LZSA2_token
    rep #$20
    inc.b LZSA2_source       ; Increment source pointer
    sep #$20

;
; Decode literal length
;
DecodeLitLen:
    and #%00011000          ; Mask literal type
    beq DecodeMatchOffset   ; No literal
    cmp #%00010000
    beq .LitLen2
    bpl .ExtLitLen

.LitLen1                   ; Copy 1 literal
    lda.b [LZSA2_source]
    sta.b [LZSA2_dest]
    rep #$20
    inc.b LZSA2_source
    inc.b LZSA2_dest
    sep #$20
    bra DecodeMatchOffset

.LitLen2                   ; Copy 2 literals
    rep #$20
    lda.b [LZSA2_source]
    sta.b [LZSA2_dest]
    inc.b LZSA2_source
    inc.b LZSA2_dest
    inc.b LZSA2_source
    inc.b LZSA2_dest
    sep #$20
    bra DecodeMatchOffset

.ExtLitLen
    jsr GetNibble
    cmp #$0f
    bne .LitLenNibble

    lda.b LZSA2_source    ; Long literal, read next byte
    cmp.b #$ef
    beq .LitLenWord

.LitLenByte                ; Literal length: Byte + nibble value + 3
    clc
    adc.b #(15+3-1)
    rep #$20
    inc.b LZSA2_source
    and.w #$00ff
    bra .CopyLiteral

.LitLenWord                ; Literal length: Next word
    rep #$20
    inc.b LZSA2_source
    lda.b LZSA2_source
    inc.b LZSA2_source
    bra .CopyLiteral

.LitLenNibble              ; Literal length: Nibble value + 3
    clc
    adc.b #(3-1)
    rep #$20
    and.w #$00ff

.CopyLiteral               ; Length in A
    ldx.b LZSA2_source       ; 4
    ldy.b LZSA2_dest         ; 4
    phb                     ; 3
    jsl LZSA2_mvl           ; 8 -> 7 * len + 6
    plb                     ; 4 25
    stx.b LZSA2_source       ; 4
    sty.b LZSA2_dest         ; 4
    sep #$20                ; 3

DecodeMatchOffset:
    lda.b LZSA2_token
    asl                     ; Shift X to C
    bcs .LongMatchOffset
    asl                     ; Shift Y to C
    bcs .MatchOffset01Z

; 00Z 5-bit offset:
; - Read a nibble for offset bits 1-4 and use the inverted bit Z of the token as bit 0 of the offset.
; - Set bits 5-15 of the offset to 1.
.MatchOffset00Z
    asl                     ; Shift Z to C
    php
    jsr GetNibble
    plp
    rol                     ; Shift nibble, Z into bit 0
    eor.b #%11100001
    xba
    lda.b #$ff
    xba
    rep #$20
    bra DecodeMatchLen

; 01Z 9-bit offset:
; Read a byte for offset bits 0-7 and use the inverted bit Z for bit 8 of the offset.
; Set bits 9-15 of the offset to 1.
.MatchOffset01Z
    asl                     ; Shift Z to C
    php
    lda.b [LZSA2_source]
    xba
    plp
    lda.b #$00
    rol
    eor.b #$ff
    xba
    rep #$20
    inc.b LZSA2_source
    bra DecodeMatchLen

.LongMatchOffset
    asl                     ; Shift Y to C, Z to N
    bcc .MatchOffset10Z
    bmi .MatchOffset111

; 110 16-bit offset:
; Read a byte for offset bits 8-15, then another byte for offset bits 0-7.
.MatchOffset110
    rep #$20
    lda.b [LZSA2_source]
    inc.b LZSA2_source
    inc.b LZSA2_source
    xba
    bra DecodeMatchLen

; 111 Repeat previous offset
.MatchOffset111
    rep #$20
    lda.b LZSA2_match
    bra DecodeMatchLen

; 10Z 13-bit offset:
; Read a nibble for offset bits 9-12 and use the inverted bit Z for bit 8 of the offset, then read a byte for offset bits 0-7.
; Set bits 13-15 of the offset to 1. Subtract 512 from the offset to get the final value.
.MatchOffset10Z:
    asl                     ; Shift Z to C
    php
    jsr GetNibble
    plp
    rol                     ; Shift nibble, Z into bit 0, C = 0
    eor.b #%11100001
    dec
    dec
    xba
    lda.b [LZSA2_source]
    rep #$20
    inc.b LZSA2_source

;
; Decode match length
;
DecodeMatchLen:             ; Match offset in A
    sta.b LZSA2_match        ; Store match offset
    sep #$20
    lda.b LZSA2_token
    and.b #%00000111          ; Mask match length
    cmp.b #%00000111
    beq .ExtMatchLen

.TokenMatchLen
    inc
    rep #$20
    and.w #$000f
    bra .CopyMatch

.ExtMatchLen
    jsr GetNibble
    cmp.b #$0f
    bne .MatchLenNibble
    lda.b [LZSA2_source]     ; Long match, read next byte
    cmp.b #$e8
    bcc .MatchLenByte
    beq Done

.MatchLenWord              ; Match length: Next word
    rep #$20
    inc.b LZSA2_source
    lda.b [LZSA2_source]
    inc.b LZSA2_source
    inc.b LZSA2_source
    dec
    bra .CopyMatch

.MatchLenByte              ; Match length: Byte + nibble value + 2
    clc
    adc.b #(7+15+2-1)
    rep #$20
    and.w #$00ff
    inc.b LZSA2_source
    bra .CopyMatch

.MatchLenNibble            ; Match length: Nibble value + 2
    clc
    adc.b #(7+2-1)
    rep #$20
    and.w #$001f

.CopyMatch                 ; Length in A, offset in LZSA2_match
    tay
    lda.b LZSA2_dest
    clc
    adc.b LZSA2_match
    tax
    tya
    ldy.b LZSA2_dest
    phb
    jsl LZSA2_mvm
    plb
    sty.b LZSA2_dest
    sep #$20
    jmp ReadToken

Done:
    rep #$20
    lda.b LZSA2_dest        ; Calculate decompressed size
    sec
    sbc 1,s                 ; Start offset on stack
    plx                     ; Unwind
    tax
    sep #$20
if !LZSA2_OPT_DMA_SCRATCHPAD = 1
    pld
endif
    rtl

;
; Get next nibble
;
GetNibble:
    lsr.b LZSA2_nibrdy       ; Nibble ready?
    bcs .NibbleReady
    inc.b LZSA2_nibrdy       ; Flag nibble ready
    lda.b [LZSA2_source]     ; Load and store next nibble
    sta.b LZSA2_nibble
    lsr
    lsr
    lsr
    lsr
    rep #$20                    ; Increment source pointer
    inc.b LZSA2_source
    sep #$20
    rts
.NibbleReady
    lda.b LZSA2_nibble
    and.b #$0f
    rts

LZSA2_DecompressBlock_END: