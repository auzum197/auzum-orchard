window.BENCHMARK_DATA = {
  "lastUpdate": 1789347277154,
  "repoUrl": "https://github.com/auzum197/auzum-orchard",
  "entries": {
    "Orchard Benchmarks": [
      {
        "commit": {
          "author": {
            "email": "dorianvp@zingolabs.org",
            "name": "dorianvp",
            "username": "dorianvp"
          },
          "committer": {
            "email": "dorianvp@zingolabs.org",
            "name": "dorianvp",
            "username": "dorianvp"
          },
          "distinct": true,
          "id": "0d65b342402a4b3be000edfcc019228f9aa51a26",
          "message": "fix: resolve clippy lints in the ported ZSA code\n\nrand 0.10's CryptoRng already requires Rng, so drop the redundant bound;\ndrop needless borrows and a needless mut; use as_chunks for the fixed\nfour-value chunks.\n\nCo-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>",
          "timestamp": "2026-09-13T21:48:12-03:00",
          "tree_id": "7af0594f4d35dc0e002812605ef705f0e9847f93",
          "url": "https://github.com/auzum197/auzum-orchard/commit/0d65b342402a4b3be000edfcc019228f9aa51a26"
        },
        "date": 1789347276272,
        "tool": "cargo",
        "benches": [
          {
            "name": "ironwood-payment-proving/1",
            "value": 509853924,
            "range": "± 47332342",
            "unit": "ns/iter"
          },
          {
            "name": "ironwood-payment-proving/2",
            "value": 620595613,
            "range": "± 4119454",
            "unit": "ns/iter"
          },
          {
            "name": "ironwood-payment-proving/3",
            "value": 867604196,
            "range": "± 18917697",
            "unit": "ns/iter"
          },
          {
            "name": "ironwood-payment-proving/4",
            "value": 1098612086,
            "range": "± 11528234",
            "unit": "ns/iter"
          },
          {
            "name": "ironwood-payment-verifying/1",
            "value": 8379305,
            "range": "± 214037",
            "unit": "ns/iter"
          },
          {
            "name": "ironwood-payment-verifying/2",
            "value": 8897157,
            "range": "± 75236",
            "unit": "ns/iter"
          },
          {
            "name": "ironwood-payment-verifying/3",
            "value": 9560381,
            "range": "± 82653",
            "unit": "ns/iter"
          },
          {
            "name": "ironwood-payment-verifying/4",
            "value": 10189460,
            "range": "± 128910",
            "unit": "ns/iter"
          }
        ]
      }
    ]
  }
}