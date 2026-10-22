#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Script de test UDP de bout en bout pour le workflow GNU Radio GFSK.

Génère des PDUs aléatoires (taille et contenu), les envoie via UDP au workflow
GNU Radio (TX), écoute les PDUs démodulées en retour (RX), et valide
l'intégrité binaire complète de la chaîne modulation/démodulation.
"""

import argparse
import os
import random
import socket
import sys
import time


def parse_args():
    parser = argparse.ArgumentParser(
        description="Test UDP bidirectionnel pour le workflow GNU Radio GFSK."
    )
    parser.add_argument(
        "--target-ip",
        default="172.17.0.9",
        help="Adresse IP du conteneur Docker exécutant GNU Radio (défaut: 172.17.0.9)",
    )
    parser.add_argument(
        "--tx-port",
        type=int,
        default=52001,
        help="Port UDP d'entrée du workflow GNU Radio (défaut: 52001)",
    )
    parser.add_argument(
        "--rx-port",
        type=int,
        default=52002,
        help="Port UDP d'écoute sur l'hôte pour la réception des PDUs (défaut: 52002)",
    )
    parser.add_argument(
        "--rx-bind-ip",
        default="0.0.0.0",
        help="Adresse IP locale de liaison pour l'écoute RX (défaut: 0.0.0.0)",
    )
    parser.add_argument(
        "--count",
        type=int,
        default=10,
        help="Nombre de PDUs aléatoires à tester (défaut: 10)",
    )
    parser.add_argument(
        "--min-size",
        type=int,
        default=12,
        help="Taille minimale d'une PDU en octets (défaut: 12)",
    )
    parser.add_argument(
        "--max-size",
        type=int,
        default=128,
        help="Taille maximale d'une PDU en octets (défaut: 128)",
    )
    parser.add_argument(
        "--interval",
        type=float,
        default=0.3,
        help="Intervalle entre chaque envoi en secondes (défaut: 0.3s)",
    )
    parser.add_argument(
        "--timeout",
        type=float,
        default=2.5,
        help="Délai d'attente maximal en secondes pour chaque réponse (défaut: 2.5s)",
    )
    return parser.parse_args()


def format_hex(data: bytes, max_len: int = 32) -> str:
    hex_str = " ".join(f"{b:02x}" for b in data[:max_len])
    if len(data) > max_len:
        hex_str += f"... (+{len(data) - max_len} octets)"
    return hex_str


def main():
    args = parse_args()

    print("=" * 70)
    print("  Test UDP Bout-en-Bout - Workflow GNU Radio KISS GFSK")
    print("=" * 70)
    print(f" • Cible TX (Docker) : {args.target_ip}:{args.tx_port}")
    print(f" • Écoute RX (Hôte)  : {args.rx_bind_ip}:{args.rx_port}")
    print(f" • Nombre de tests   : {args.count} PDUs")
    print(f" • Gamme de taille   : [{args.min_size}, {args.max_size}] octets")
    print(f" • Timeout par trame : {args.timeout} s")
    print("-" * 70)

    # Création du socket de réception
    rx_sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    rx_sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    try:
        rx_sock.bind((args.rx_bind_ip, args.rx_port))
    except Exception as e:
        print(f"\n[ERREUR] Impossible de lier le port RX {args.rx_bind_ip}:{args.rx_port} : {e}")
        sys.exit(1)

    rx_sock.settimeout(args.timeout)

    # Socket d'émission
    tx_sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)

    # Vider d'éventuels paquets résiduels dans le buffer de réception
    rx_sock.setblocking(False)
    flushed = 0
    try:
        while True:
            _, _ = rx_sock.recvfrom(65535)
            flushed += 1
    except BlockingIOError:
        pass
    if flushed:
        print(f" • {flushed} paquet(s) résiduel(s) purgé(s) du buffer de réception.")

    rx_sock.setblocking(True)
    rx_sock.settimeout(args.timeout)

    success_count = 0
    timeout_count = 0
    corrupted_count = 0
    rtts = []

    print("\nDémarrage de la séquence de test...")

    for i in range(1, args.count + 1):
        # Générer une taille et un contenu aléatoire
        size = random.randint(args.min_size, args.max_size)
        payload_sent = os.urandom(size)

        print(f"\n[{i:02d}/{args.count:02d}] Envoi de {size} octets -> {args.target_ip}:{args.tx_port}")
        print(f"       Hex : {format_hex(payload_sent)}")

        t_start = time.perf_counter()
        try:
            tx_sock.sendto(payload_sent, (args.target_ip, args.tx_port))
        except Exception as e:
            print(f"       [ERREUR ENVOI] {e}")
            continue

        # Attente de la réception décodée
        try:
            payload_recv, src_addr = rx_sock.recvfrom(65535)
            rtt = (time.perf_counter() - t_start) * 1000.0
            rtts.append(rtt)

            if payload_recv == payload_sent:
                print(f"       [SUCCÈS] PDU reçue identique de {src_addr[0]}:{src_addr[1]} en {rtt:.2f} ms")
                success_count += 1
            else:
                print(f"       [ÉCHEC] PDU corrompue reçue ({len(payload_recv)} octets vs {size} attendus) !")
                print(f"       Reçu : {format_hex(payload_recv)}")
                corrupted_count += 1
        except socket.timeout:
            print(f"       [TIMEOUT] Aucune PDU reçue après {args.timeout} s")
            timeout_count += 1

        time.sleep(args.interval)

    tx_sock.close()
    rx_sock.close()

    print("\n" + "=" * 70)
    print("  RÉSUMÉ DU TEST")
    print("=" * 70)
    print(f" • Trames émises      : {args.count}")
    print(f" • Succès (100% exact): {success_count} ({success_count / args.count * 100:.1f}%)")
    print(f" • Timeouts (Perdues) : {timeout_count}")
    print(f" • Corrompues         : {corrupted_count}")
    if rtts:
        avg_rtt = sum(rtts) / len(rtts)
        print(f" • RTT Moyen          : {avg_rtt:.2f} ms (min: {min(rtts):.2f} ms, max: {max(rtts):.2f} ms)")
    print("=" * 70)

    if success_count == args.count:
        print("\nRésultat : [VALIDÉ] La chaîne complète GFSK fonctionne parfaitement !")
        return 0
    else:
        print(f"\nRésultat : [ÉCHEC] {args.count - success_count} trame(s) non reçue(s) ou incorrecte(s).")
        return 1


if __name__ == "__main__":
    sys.exit(main())
