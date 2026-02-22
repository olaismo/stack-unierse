;; ----------------------------------------------------------
;; Contract: stack-universe
;; A mega-contract combining:
;; Staking + Yield Farming + Insurance + Crowdfunding + 
;; Prediction Markets + DAO Governance + Treasury + Reputation + NFTs
;; ----------------------------------------------------------

(define-trait i-nft
  ((mint (principal uint) (response uint uint))
   (transfer (uint principal principal) (response bool uint))
   (owner-of (uint) (response (optional principal) uint))))

;; -----------------------
;; Global State & Maps
;; -----------------------
(define-data-var total-staked uint u0)
(define-data-var reward-rate uint u100)
(define-data-var nft-counter uint u0)
(define-data-var proposal-counter uint u0)

(define-map stakes {staker: principal}
  {amount: uint, lock-period: uint, start-height: uint, claimed: uint})

(define-map rewards {staker: principal}
  {harvest-tokens: uint, nfts-earned: uint})

(define-map insurance-pools {pool-id: uint}
  {creator: principal, balance: uint})

(define-map policies {policy-id: uint}
  {owner: principal, pool-id: uint, premium: uint, active: bool})

(define-map claims {claim-id: uint}
  {pool-id: uint, claimant: principal, reason: (string-ascii 200), amount: uint, approved: bool, executed: bool})

(define-map projects {project-id: uint}
  {creator: principal, goal: uint, raised: uint, milestones: uint, active: bool})

(define-map backers {project-id: uint, backer: principal}
  {amount: uint, voted: bool})

(define-map milestones {project-id: uint, ms-id: uint}
  {amount: uint, approved: bool, released: bool})

(define-map markets {market-id: uint}
  {creator: principal, description: (string-ascii 200), options: (string-ascii 50), end-block: uint, resolved: bool, winning-option: (string-ascii 50)})

(define-map bets {market-id: uint, bettor: principal}
  {option: (string-ascii 50), amount: uint, claimed: bool})

(define-map proposals {proposal-id: uint}
  {proposer: principal, description: (string-ascii 200), votes-for: uint, votes-against: uint, executed: bool})

(define-map treasury {id: uint}
  {balance: uint})

(define-map reputation {user: principal}
  {score: int})

;; -----------------------
;; Helper
;; -----------------------
(define-private (current-block) u0)

(define-private (calculate-reward (amount uint))
  (* amount (var-get reward-rate)))

;; -----------------------
;; STAKING MODULE
;; -----------------------
(define-public (stake (amount uint) (lock-period uint))
  (begin
    (asserts! (and (> amount u0) (> lock-period u0)) (err u0))
    (try! (stx-transfer? amount tx-sender (as-contract tx-sender)))
    (map-set stakes {staker: tx-sender}
      {amount: amount, lock-period: lock-period, start-height: (current-block), claimed: u0})
    (var-set total-staked (+ (var-get total-staked) amount))
    (ok true)))

(define-public (unstake)
  (let ((s (map-get? stakes {staker: tx-sender})))
    (match s st
      (if (>= (- (current-block) (get start-height st)) (get lock-period st))
        (begin
          (try! (stx-transfer? (get amount st) (as-contract tx-sender) tx-sender))
          (map-delete stakes {staker: tx-sender})
          (ok true))
        (err u100))
      (err u101))))

(define-public (claim-reward)
  (let ((s (map-get? stakes {staker: tx-sender})))
    (match s st 
      (begin
        (map-set rewards {staker: tx-sender}
          {harvest-tokens: (calculate-reward (get amount st)),
           nfts-earned: u1})
        (var-set nft-counter (+ (var-get nft-counter) u1))
        (ok true))
      (err u200))))

;; -----------------------
;; INSURANCE MODULE
;; -----------------------
(define-public (create-pool (pool-id uint))
  (begin
    (asserts! (> pool-id u0) (err u0))
    (map-set insurance-pools {pool-id: pool-id} {creator: tx-sender, balance: u0})
    (ok pool-id)))

(define-public (buy-insurance (policy-id uint) (pool-id uint) (premium uint))
  (let ((pool (unwrap-panic (map-get? insurance-pools {pool-id: pool-id}))))
    (begin
      (asserts! (and (> policy-id u0) (> pool-id u0) (> premium u0)) (err u0))
      (try! (stx-transfer? premium tx-sender (as-contract tx-sender)))
      (map-set policies {policy-id: policy-id} {owner: tx-sender, pool-id: pool-id, premium: premium, active: true})
      (map-set insurance-pools {pool-id: pool-id} {creator: (get creator pool), balance: (+ premium (get balance pool))})
      (ok true))))

(define-public (submit-claim (claim-id uint) (pool-id uint) (reason (string-ascii 200)) (amount uint))
  (begin
    (asserts! (and (> claim-id u0) (> pool-id u0) (> amount u0) (> (len reason) u0)) (err u0))
    (map-set claims {claim-id: claim-id} {pool-id: pool-id, claimant: tx-sender, reason: reason, amount: amount, approved: false, executed: false})
    (ok claim-id)))

(define-public (vote-claim (claim-id uint) (approve bool))
  (let ((c (map-get? claims {claim-id: claim-id})))
    (begin
      (asserts! (> claim-id u0) (err u0))
      (match c cl
        (begin
          (map-set claims {claim-id: claim-id} (merge cl {approved: approve}))
          (ok true))
        (err u301)))))

(define-public (payout-claim (claim-id uint))
  (let ((c (map-get? claims {claim-id: claim-id})))
    (begin
      (asserts! (> claim-id u0) (err u0))
      (match c cl
        (if (and (get approved cl) (not (get executed cl)))
          (begin
            (try! (stx-transfer? (get amount cl) (as-contract tx-sender) (get claimant cl)))
            (map-set claims {claim-id: claim-id} (merge cl {executed: true}))
            (ok true))
          (err u400))
        (err u401)))))

;; -----------------------
;; CROWDFUNDING MODULE
;; -----------------------
(define-public (create-project (project-id uint) (goal uint) (num-milestones uint))
  (begin
    (asserts! (and (> project-id u0) (> goal u0) (> num-milestones u0)) (err u0))
    (map-set projects {project-id: project-id} {creator: tx-sender, goal: goal, raised: u0, milestones: num-milestones, active: true})
    (ok project-id)))

(define-public (back-project (project-id uint) (amount uint))
  (begin
    (asserts! (and (> project-id u0) (> amount u0)) (err u0))
    (try! (stx-transfer? amount tx-sender (as-contract tx-sender)))
    (map-set backers {project-id: project-id, backer: tx-sender} {amount: amount, voted: false})
    (ok true)))

(define-public (vote-milestone (project-id uint) (ms-id uint) (approve bool))
  (let ((m (map-get? milestones {project-id: project-id, ms-id: ms-id})))
    (begin
      (asserts! (and (> project-id u0) (> ms-id u0)) (err u0))
      (match m mi
        (begin
          (map-set milestones {project-id: project-id, ms-id: ms-id} {amount: (get amount mi), approved: approve, released: (get released mi)})
          (ok true))
        (err u501)))))

(define-public (release-milestone (project-id uint) (ms-id uint))
  (let ((m (map-get? milestones {project-id: project-id, ms-id: ms-id})))
    (begin
      (asserts! (and (> project-id u0) (> ms-id u0)) (err u0))
      (match m mi
        (if (and (get approved mi) (not (get released mi)))
          (begin
            (try! (stx-transfer? (get amount mi) (as-contract tx-sender) (get creator (unwrap-panic (map-get? projects {project-id: project-id})))))
            (map-set milestones {project-id: project-id, ms-id: ms-id} (merge mi {released: true}))
            (ok true))
          (err u600))
        (err u601)))))

;; -----------------------
;; PREDICTION MARKETS MODULE
;; -----------------------
(define-public (create-market (market-id uint) (description (string-ascii 200)) (options (string-ascii 50)) (end-block uint))
  (begin
    (asserts! (and (> market-id u0) (> end-block u0) (> (len description) u0) (> (len options) u0)) (err u0))
    (map-set markets {market-id: market-id} {creator: tx-sender, description: description, options: options, end-block: end-block, resolved: false, winning-option: ""})
    (ok market-id)))

(define-public (bet (market-id uint) (option (string-ascii 50)) (amount uint))
  (begin
    (asserts! (and (> market-id u0) (> amount u0) (> (len option) u0)) (err u0))
    (try! (stx-transfer? amount tx-sender (as-contract tx-sender)))
    (map-set bets {market-id: market-id, bettor: tx-sender} {option: option, amount: amount, claimed: false})
    (ok true)))

(define-public (resolve-market (market-id uint) (winning-option (string-ascii 50)))
  (begin
    (asserts! (> market-id u0) (err u0))
    (map-set markets {market-id: market-id} (merge (unwrap-panic (map-get? markets {market-id: market-id})) {resolved: true, winning-option: winning-option}))
    (ok true)))

(define-public (claim-winnings (market-id uint))
  (let ((b (map-get? bets {market-id: market-id, bettor: tx-sender})))
    (begin
      (asserts! (> market-id u0) (err u0))
      (match b bt
        (let ((m (unwrap-panic (map-get? markets {market-id: market-id}))))
          (if (and (get resolved m) (is-eq (get option bt) (get winning-option m)) (not (get claimed bt)))
            (begin
              (try! (stx-transfer? (get amount bt) (as-contract tx-sender) tx-sender))
              (map-set bets {market-id: market-id, bettor: tx-sender} (merge bt {claimed: true}))
              (ok true))
            (err u700)))
        (err u701)))))

;; -----------------------
;; DAO GOVERNANCE
;; -----------------------
(define-public (create-proposal (description (string-ascii 200)))
  (let ((id (+ (var-get proposal-counter) u1)))
    (begin
      (asserts! (> (len description) u0) (err u0))
      (var-set proposal-counter id)
      (map-set proposals {proposal-id: id} {proposer: tx-sender, description: description, votes-for: u0, votes-against: u0, executed: false})
      (ok id))))

(define-public (vote-proposal (proposal-id uint) (support bool))
  (let ((p (map-get? proposals {proposal-id: proposal-id})))
    (begin
      (asserts! (> proposal-id u0) (err u0))
      (match p prop
        (if (not (get executed prop))
          (begin
            (if support
              (map-set proposals {proposal-id: proposal-id} (merge prop {votes-for: (+ (get votes-for prop) u1)}))
              (map-set proposals {proposal-id: proposal-id} (merge prop {votes-against: (+ (get votes-against prop) u1)})))
            (ok true))
          (err u800))
        (err u801)))))

(define-public (execute-proposal (proposal-id uint))
  (let ((p (map-get? proposals {proposal-id: proposal-id})))
    (begin
      (asserts! (> proposal-id u0) (err u0))
      (match p prop
        (if (and (not (get executed prop)) (> (get votes-for prop) (get votes-against prop)))
          (begin
            (map-set proposals {proposal-id: proposal-id} (merge prop {executed: true}))
            (ok true))
          (err u900))
        (err u901)))))

;; -----------------------
;; TREASURY
;; -----------------------
(define-public (fund-treasury (amount uint))
  (begin
    (asserts! (> amount u0) (err u0))
    (try! (stx-transfer? amount tx-sender (as-contract tx-sender)))
    (map-set treasury {id: u1} {balance: (+ amount (get balance (default-to {balance: u0} (map-get? treasury {id: u1}))))})
    (ok true)))

(define-public (spend-treasury (amount uint) (recipient principal))
  (let ((t (map-get? treasury {id: u1})))
    (begin
      (asserts! (and (> amount u0) (is-some (some recipient))) (err u0))
      (match t tre
        (if (>= (get balance tre) amount)
          (begin
            (try! (stx-transfer? amount (as-contract tx-sender) recipient))
            (map-set treasury {id: u1} {balance: (- (get balance tre) amount)})
            (ok true))
          (err u1000))
        (err u1001)))))

;; -----------------------
;; REPUTATION
;; -----------------------
(define-public (update-reputation (user principal) (delta int))
  (let ((rep (map-get? reputation {user: user})))
    (begin
      (asserts! (is-some (some user)) (err u0))
      (if (is-some rep)
        (map-set reputation {user: user} (merge (unwrap-panic rep) {score: (+ (get score (unwrap-panic rep)) delta)}))
        (begin
          (asserts! (is-some (some delta)) (err u0))
          (map-set reputation {user: user} {score: delta})))
      (ok true))))
