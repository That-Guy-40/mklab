\ sha256.fth — SHA-256 (FIPS 180-4) in OpenBIOS Forth (B.3 Spike 1b).
\
\ THE CRUX DEPENDENCY OF THE ATTESTATION HALF. A TPM PCR is an iterated hash,
\ PCR = SHA256(PCR ‖ digest), so replaying a measured-boot event log is 100%
\ software and needs no TPM — but it needs SHA-256, which this Forth did not have.
\ This is it, once, as a PURE FUNCTION: no I/O, no device, no host word — which is
\ exactly why it is the cleanest thing in the toolkit to validate across the
\ endianness × width matrix. The same source must produce the same digest on a
\ 32-bit BE ppc, a 32-bit LE x86 and 64-bit LE amd64/unix; the NIST test vectors
\ are the control, and a wrong answer on any one arch names a real bug in either
\ this file or the arch (a 32-bit-masking slip shows only on 64-bit cells; a
\ byte-order slip in the word loads shows only across BE/LE).
\
\ WIDTH DISCIPLINE. SHA-256 is 32-bit modular arithmetic. A cell is 64 bits on
\ amd64/unix and 32 on x86/ppc, so every add and left-shift is masked back to 32
\ bits with m32 — on a 32-bit cell that mask is the identity, on a 64-bit cell it
\ is what keeps the carries from leaking into bits the algorithm never has.
\
\ BYTE ORDER. Message words and the output digest are BIG-endian per the spec;
\ l@-be / l!-be (bytewise, in forth/device/property.fs) do that on every arch.
\
\ Sized for this lab's inputs (the replay hashes 64 bytes; the longest NIST vector
\ here is 56): the padding buffer holds up to 447 bytes of message (7 blocks).
\ Load struct.fth first (for .hx2). Base is hex.
hex

: m32   ( x -- x32 )       ffffffff and ;
: rotr  ( x n -- y )       2dup rshift >r  20 swap - lshift m32  r> or ;
: ch    ( x y z -- r )     >r over and  swap invert m32 r> and  or m32 ;   \ (x&y) ^ (~x&z)
: maj   ( x y z -- r )     >r 2dup and  -rot or r> and  or m32 ;          \ (x&y) | ((x|y)&z)
\ rotation counts are hex: 0d=13 16=22 0b=11 19=25 12=18 11=17 13=19 0a=10
: bsig0 ( x -- r )         dup 2 rotr  over 0d rotr xor  swap 16 rotr xor ;  \ ROTR2^ROTR13^ROTR22
: bsig1 ( x -- r )         dup 6 rotr  over 0b rotr xor  swap 19 rotr xor ;  \ ROTR6^ROTR11^ROTR25
: ssig0 ( x -- r )         dup 7 rotr  over 12 rotr xor  swap 3 rshift xor ; \ ROTR7^ROTR18^SHR3
: ssig1 ( x -- r )         dup 11 rotr  over 13 rotr xor  swap 0a rshift xor ; \ ROTR17^ROTR19^SHR10

\ the 64 round constants (first 32 bits of the fractional parts of the cube roots
\ of the first 64 primes). Stored one per CELL (`,`) so the same source indexes
\ them on 32- and 64-bit cells alike; every value is < 2^32.
create K
428a2f98 , 71374491 , b5c0fbcf , e9b5dba5 , 3956c25b , 59f111f1 , 923f82a4 , ab1c5ed5 ,
d807aa98 , 12835b01 , 243185be , 550c7dc3 , 72be5d74 , 80deb1fe , 9bdc06a7 , c19bf174 ,
e49b69c1 , efbe4786 , 0fc19dc6 , 240ca1cc , 2de92c6f , 4a7484aa , 5cb0a9dc , 76f988da ,
983e5152 , a831c66d , b00327c8 , bf597fc7 , c6e00bf3 , d5a79147 , 06ca6351 , 14292967 ,
27b70a85 , 2e1b2138 , 4d2c6dfc , 53380d13 , 650a7354 , 766a0abb , 81c2c92e , 92722c85 ,
a2bfe8a1 , a81a664b , c24b8b70 , c76c51a3 , d192e819 , d6990624 , f40e3585 , 106aa070 ,
19a4c116 , 1e376c08 , 2748774c , 34b0bcb5 , 391c0cb3 , 4ed8aa4a , 5b9cca4f , 682e6ff3 ,
748f82ee , 78a5636f , 84c87814 , 8cc70208 , 90befffa , a4506ceb , bef9a3f7 , c67178f2 ,

create Hst   8 cells allot          \ the running hash state H0..H7
create W    40 cells allot          \ the 64-word message schedule
variable va variable vb variable vc variable vd
variable ve variable vf variable vg variable vh

: sha256-init ( -- )
  6a09e667 Hst 0 cells + !  bb67ae85 Hst 1 cells + !
  3c6ef372 Hst 2 cells + !  a54ff53a Hst 3 cells + !
  510e527f Hst 4 cells + !  9b05688c Hst 5 cells + !
  1f83d9ab Hst 6 cells + !  5be0cd19 Hst 7 cells + ! ;

\ one 64-byte block at `adr` (message words are BIG-endian)
: sha256-block ( adr -- )
  10 0 do  dup i 4 * + l@-be  W i cells + !  loop drop        \ W[0..15]
  40 10 do                                                    \ W[16..63]
    W i 2 - cells + @ ssig1   W i 7 - cells + @ +
    W i f - cells + @ ssig0 + W i 10 - cells + @ + m32
    W i cells + !
  loop
  Hst 0 cells + @ va !  Hst 1 cells + @ vb !  Hst 2 cells + @ vc !  Hst 3 cells + @ vd !
  Hst 4 cells + @ ve !  Hst 5 cells + @ vf !  Hst 6 cells + @ vg !  Hst 7 cells + @ vh !
  40 0 do
    \ T1 = h + BSIG1(e) + CH(e,f,g) + K[i] + W[i]
    vh @  ve @ bsig1 +  ve @ vf @ vg @ ch +  K i cells + @ +  W i cells + @ + m32
    \ T2 = BSIG0(a) + MAJ(a,b,c)
    va @ bsig0  va @ vb @ vc @ maj + m32                ( T1 T2 )
    vg @ vh !  vf @ vg !  ve @ vf !                     \ h=g g=f f=e
    over vd @ + m32 ve !                                \ e = d + T1
    vc @ vd !  vb @ vc !  va @ vb !                     \ d=c c=b b=a
    + m32 va !                                          \ a = T1 + T2
  loop
  va @ Hst 0 cells + +!  vb @ Hst 1 cells + +!  vc @ Hst 2 cells + +!  vd @ Hst 3 cells + +!
  ve @ Hst 4 cells + +!  vf @ Hst 5 cells + +!  vg @ Hst 6 cells + +!  vh @ Hst 7 cells + +!
  8 0 do  Hst i cells + dup @ m32 swap !  loop ;        \ keep H in 32 bits on 64-bit cells

\ padding buffer + the 32-byte output digest
create padbuf 200 allot
create digest 20 allot

\ sha256 ( adr len -- digest-adr ): hash `len` bytes at `adr`; the 32-byte
\ big-endian digest is left in `digest` (a static buffer — copy it out if you
\ need it to survive the next call). Refuses a message the pad buffer cannot
\ hold rather than overrunning it.
: sha256 ( adr len -- digest-adr )
  dup 1bf > if ." SHA256-TOO-LONG" cr 2drop digest exit then
  dup >r                                  ( adr len ) ( r: len )
  padbuf 200 erase
  padbuf swap move                        \ message
  padbuf r@ + 80 swap c!                  \ the 0x80 terminator
  \ padded length: smallest multiple of 64 >= len+1+8
  r@ 9 + 3f + 40 negate and               ( padlen )
  \ bit length, 64-bit big-endian, in the last 8 bytes: high word 0 (len < 2^29)
  dup padbuf + 8 - >r
  0 r@ l!-be   r> 4 + r> 8 * swap l!-be   ( padlen )
  sha256-init
  40 / 0 do  padbuf i 40 * + sha256-block  loop
  8 0 do  Hst i cells + @  digest i 4 * +  l!-be  loop
  digest ;

\ print a 32-byte digest as 64 contiguous lowercase hex digits (no spaces —
\ so a host can diff it against python hashlib / tpm2_eventlog verbatim).
: .digest ( adr -- )  20 0 do  dup i + c@ .hx2  loop drop ;
