// RapidWright helper for the F2 nested-DFX prefetcher child flow (RapidWright 2025.2.2).
// STATUS (2026-10-15, trials rw_a/rw_a2): RapidWright cannot load the F2 base or its WRAPPER/CL: the DCP's
// embedded EDIF is encrypted and Vivado refuses a readable one (write_edif: EDIF 20-92 "security attribute"
// on the AWS top; Designutils 20-2284 "IEEE 1735 V2" IP inside WRAPPER/CL; RW auto-generation uses the
// same write_edif). Only RM-level checkpoints are readable (roundtrip of the routed AMPM RP cell: 3.6 s).
// 'stitch' and 'route' are therefore compiled but never ran on the real design.
// Single-file Java (launch via run_rw.sh). Subcommands:
//   roundtrip <in.dcp> <in.edf|-> <out.dcp>
//       time readCheckpoint + writeCheckpoint, print design stats (A).
//   stitch <base.dcp> <base.edf|-> <rm.dcp> <rm.edf|-> <rp_hier> <pplocs.txt> <out.dcp> [route=1]
//       black-box the RP in the base (static GND/VCC and static-side boundary routing kept),
//       populate it with the placed+routed RM cell checkpoint, partially route what is left
//       (boundary sinks), write DCP (B/C).
//   route <in.dcp> <in.edf|-> <out.dcp> [timing=0]
//       RWRoute partial routing of all unrouted pins, existing routing preserved (D).
import com.xilinx.rapidwright.design.*;
import com.xilinx.rapidwright.device.*;
import com.xilinx.rapidwright.edif.*;
import com.xilinx.rapidwright.rwroute.*;
import java.nio.file.*;
import java.util.*;

public class RwDcp {
    static long T0 = System.nanoTime();
    static long tPrev = T0;

    static void t(String k) {
        long now = System.nanoTime();
        System.out.printf("RW_TIME %s %.1f%n", k, (now - tPrev) / 1e9);
        tPrev = now;
    }

    static Design read(String dcp, String edf) {
        tPrev = System.nanoTime();
        Design d = edf.equals("-") ? Design.readCheckpoint(dcp) : Design.readCheckpoint(dcp, edf);
        t("read " + Paths.get(dcp).getFileName());
        return d;
    }

    static void stats(String tag, Design d) {
        long pips = 0;
        int routed = 0;
        for (Net n : d.getNets()) {
            pips += n.getPIPs().size();
            if (n.hasPIPs()) routed++;
        }
        EDIFNetlist nl = d.getNetlist();
        System.out.printf("RW_STAT %s part=%s top=%s cells=%d siteinsts=%d nets=%d routedNets=%d pips=%d "
                        + "encrypted=%d ooc=%b adv=%b%n",
                tag, d.getPartName(), nl.getTopCell().getName(), d.getCells().size(), d.getSiteInsts().size(),
                d.getNets().size(), routed, pips, nl.getEncryptedCells().size(), d.isDesignOutOfContext(),
                d.isAdvancedFlow());
        for (String e : nl.getEncryptedCells()) System.out.println("RW_ENC " + tag + " " + e);
        for (ConstraintGroup g : ConstraintGroup.values()) {
            List<String> x = d.getXDCConstraints(g);
            System.out.println("RW_XDC " + tag + " " + g + " lines=" + (x == null ? 0 : x.size()));
            if (x != null) {
                int i = 0;
                for (String l : x) {
                    if (l.contains("HD.") || l.contains("pblock") || l.contains("PARTPIN") || l.contains("RECONFIG")
                            || l.contains("CONTAINER") || l.contains("LOCK")) {
                        if (i++ < 40) System.out.println("RW_XDCL " + tag + " " + g + ": " + l);
                    }
                }
            }
        }
    }

    public static void main(String[] a) throws Exception {
        switch (a[0]) {
            case "roundtrip": {
                Design d = read(a[1], a[2]);
                stats("in", d);
                t("stats");
                d.writeCheckpoint(a[3]);
                t("write " + Paths.get(a[3]).getFileName());
                break;
            }
            case "stitch":
                stitch(a);
                break;
            case "route": {
                Design d = read(a[1], a[2]);
                boolean timing = a.length > 4 && a[4].equals("1");
                List<SitePinInst> pins = PartialRouter.getUnroutedPins(d);
                System.out.println("RW_ROUTE unrouted pins=" + pins.size());
                t("prep");
                if (timing) PartialRouter.routeDesignPartialTimingDriven(d, pins, false);
                else PartialRouter.routeDesignPartialNonTimingDriven(d, pins, false);
                t("rwroute");
                System.out.println("RW_ROUTE still unrouted=" + PartialRouter.getUnroutedPins(d).size());
                d.writeCheckpoint(a[3]);
                t("write");
                break;
            }
            default:
                throw new IllegalArgumentException(a[0]);
        }
        System.out.printf("RW_TIME total %.1f%n", (System.nanoTime() - T0) / 1e9);
    }

    // ---------------------------------------------------------------- stitch
    static Node node(String s) {
        return Node.getNode(s.replaceAll("[{}]", "").trim(), dev);
    }

    static Device dev;

    /**
     * Prune dangling PIP branches of a net: repeatedly drop PIPs whose end node feeds nothing else in the
     * net and is not a kept terminal (sink site pin node or a partition-pin node).
     */
    static int pruneDangling(Net n, Set<Node> keep, boolean srcSide) {
        List<PIP> pips = new ArrayList<>(n.getPIPs());
        if (pips.isEmpty()) return 0;
        Map<Node, Integer> fanout = new HashMap<>();
        Map<Node, List<PIP>> byEnd = new HashMap<>();
        for (PIP p : pips) {
            fanout.merge(p.getStartNode(), 1, Integer::sum);
            byEnd.computeIfAbsent(p.getEndNode(), k -> new ArrayList<>()).add(p);
            if (p.isBidirectional()) {
                fanout.merge(p.getEndNode(), 1, Integer::sum);
            }
        }
        Set<Node> term = new HashSet<>(keep);
        for (SitePinInst sp : n.getPins()) {
            if (!sp.isOutPin()) term.add(sp.getConnectedNode());
        }
        Set<PIP> drop = new HashSet<>();
        Deque<Node> work = new ArrayDeque<>();
        for (Node e : byEnd.keySet()) if (!fanout.containsKey(e) && !term.contains(e)) work.add(e);
        while (!work.isEmpty()) {
            Node e = work.poll();
            List<PIP> in = byEnd.remove(e);
            if (in == null) continue;
            for (PIP p : in) {
                if (!drop.add(p)) continue;
                Node s = p.getStartNode();
                int f = fanout.merge(s, -1, Integer::sum);
                if (f <= 0 && !term.contains(s)) work.add(s);
            }
        }
        if (srcSide) {
            // Source side (non-static nets only): drop PIPs whose start node is neither driven by another
            // kept PIP nor the source site-pin node nor a kept terminal (orphaned old-RM driver branch).
            Map<Node, Integer> indeg = new HashMap<>();
            Map<Node, List<PIP>> byStart = new HashMap<>();
            for (PIP p : pips) {
                if (drop.contains(p)) continue;
                indeg.merge(p.getEndNode(), 1, Integer::sum);
                byStart.computeIfAbsent(p.getStartNode(), k -> new ArrayList<>()).add(p);
            }
            Set<Node> srcs = new HashSet<>(keep);
            for (SitePinInst sp : n.getPins()) if (sp.isOutPin()) srcs.add(sp.getConnectedNode());
            Deque<Node> w2 = new ArrayDeque<>();
            for (Node s : byStart.keySet()) if (!indeg.containsKey(s) && !srcs.contains(s)) w2.add(s);
            while (!w2.isEmpty()) {
                Node s = w2.poll();
                List<PIP> out = byStart.remove(s);
                if (out == null) continue;
                for (PIP p : out) {
                    if (!drop.add(p)) continue;
                    Node e = p.getEndNode();
                    int f = indeg.merge(e, -1, Integer::sum);
                    if (f <= 0 && !srcs.contains(e) && !term.contains(e)) w2.add(e);
                }
            }
        }
        if (!drop.isEmpty()) {
            List<PIP> keepP = new ArrayList<>();
            for (PIP p : pips) if (!drop.contains(p)) keepP.add(p);
            n.setPIPs(keepP);
        }
        return drop.size();
    }

    static void stitch(String[] a) throws Exception {
        String rp = a[5];
        boolean route = a.length <= 8 || a[8].equals("1");
        Design base = read(a[1], a[2]);
        dev = base.getDevice();
        Design rm = read(a[3], a[4]);
        stats("base", base);
        stats("rm", rm);
        t("stats");

        // Partition-pin nodes (from Vivado HD.ASSIGNED_PPLOCS of the base RP pins): the static-side
        // route of a boundary net ends there and must be kept as-is (static is locked; pr_verify).
        Set<Node> ppNodes = new HashSet<>();
        for (String l : Files.readAllLines(Paths.get(a[6]))) {
            String[] f = l.trim().split("\\s+", 2);
            if (f.length < 2) continue;
            for (String s : f[1].replaceAll("[{}]", " ").trim().split("\\s+")) {
                if (s.isEmpty()) continue;
                Node nd = Node.getNode(s, dev);
                if (nd == null) System.out.println("RW_WARN bad ppnode " + s);
                else ppNodes.add(nd);
            }
        }
        System.out.println("RW_STITCH ppnodes=" + ppNodes.size());

        // Snapshot routing of static nets and of every net touching the RP before makeBlackBox:
        // RapidWright's makeBlackBox unroutes GND/VCC design-wide and unroutes boundary nets back to
        // their branch point, both of which would modify locked static (AWS shell + FireSim CL) routing.
        Map<String, List<PIP>> snap = new HashMap<>();
        snap.put(base.getGndNet().getName(), new ArrayList<>(base.getGndNet().getPIPs()));
        snap.put(base.getVccNet().getName(), new ArrayList<>(base.getVccNet().getPIPs()));
        EDIFHierCellInst rpInst = base.getNetlist().getHierCellInstFromName(rp);
        Set<String> bnets = new HashSet<>();
        Map<String, String> renamed = new HashMap<>();
        for (EDIFPortInst pi : rpInst.getInst().getPortInsts()) {
            if (pi.getNet() == null) continue;
            EDIFHierNet hn = new EDIFHierNet(rpInst.getParent(), pi.getNet());
            String pn = base.getNetlist().getParentNet(hn).getHierarchicalNetName();
            Net n = base.getNet(pn);
            if (n != null && !n.isStaticNet()) {
                bnets.add(pn);
                snap.put(pn, new ArrayList<>(n.getPIPs()));
                // makeBlackBox renames a net whose driver was inside the RP to its outside segment
                if (pi.isOutput()) renamed.put(pn, hn.getHierarchicalNetName());
            }
        }
        System.out.println("RW_STITCH boundary nets=" + bnets.size());
        t("snapshot");

        // makeBlackBox -> unrouteGNDNetAndLUTSources also removes the intra-site routing of every LUT that
        // sources GND design-wide; record those (site, LUT out pin, site pin) to put back afterwards.
        List<Object[]> lutGnd = new ArrayList<>();
        Set<Node> gndStarts = new HashSet<>();
        for (PIP p : base.getGndNet().getPIPs()) gndStarts.add(p.getStartNode());
        for (Node nd : gndStarts) {
            SitePin sp = nd.getSitePin();
            if (sp != null && !sp.isInput() && com.xilinx.rapidwright.util.Utils.isSLICE(sp.getSite().getSiteTypeEnum())) {
                BELPin src = sp.getBELPin().getSourcePin();
                if (src.getBEL().isLUT()) lutGnd.add(new Object[]{sp.getSite(), src, sp.getBELPin()});
            }
        }
        System.out.println("RW_STITCH LUT GND sources=" + lutGnd.size());
        DesignTools.makeBlackBox(base, rp);
        t("makeBlackBox");
        int relut = 0;
        for (Object[] o : lutGnd) {
            SiteInst si = base.getSiteInstFromSite((Site) o[0]);
            if (si == null) continue;
            si.routeIntraSiteNet(base.getGndNet(), (BELPin) o[1], (BELPin) o[2]);
            relut++;
        }
        System.out.println("RW_STITCH LUT GND site routes restored=" + relut);

        // Restore snapshotted routing, then prune only branches that now lead nowhere (old RM sinks).
        long restored = 0, pruned = 0;
        for (Map.Entry<String, List<PIP>> e : snap.entrySet()) {
            Net n = base.getNet(e.getKey());
            if (n == null && renamed.containsKey(e.getKey())) n = base.getNet(renamed.get(e.getKey()));
            if (n == null) {
                System.out.println("RW_WARN net vanished " + e.getKey());
                continue;
            }
            n.setPIPs(e.getValue());
            restored += e.getValue().size();
            pruned += pruneDangling(n, ppNodes, !n.isStaticNet());
        }
        System.out.println("RW_STITCH restored pips=" + restored + " pruned=" + pruned);
        t("restore+prune");

        Set<PIP> rmPips = new HashSet<>();
        for (Net n : rm.getNets()) if (!n.isStaticNet()) rmPips.addAll(n.getPIPs());
        DesignTools.populateBlackBox(base, rp, rm, true);
        t("populateBlackBox");
        base.getNetlist().resetParentNetMap();
        DesignTools.makePhysNetNamesConsistent(base);
        DesignTools.createMissingSitePinInsts(base);
        // Boundary-net connectivity: PIPs not reachable from the net's source. RM-side ones (RM partition
        // pin != base PPLOC, e.g. after OOC implementation) are dropped so RWRoute reconnects those sinks;
        // static-side orphans are only reported (static routing is locked).
        int orphRm = 0, orphStatic = 0, discNets = 0;
        EDIFHierCellInst rpNow = base.getNetlist().getHierCellInstFromName(rp);
        Set<Net> bNow = new HashSet<>();
        for (EDIFPortInst pi : rpNow.getInst().getPortInsts()) {
            if (pi.getNet() == null) continue;
            EDIFHierNet hn = new EDIFHierNet(rpNow.getParent(), pi.getNet());
            Net n = base.getNet(base.getNetlist().getParentNet(hn).getHierarchicalNetName());
            if (n != null && !n.isStaticNet() && !n.isClockNet()) bNow.add(n);
        }
        for (Net n : bNow) {
            SitePinInst src = n.getSource();
            if (src == null || !n.hasPIPs()) continue;
            Map<Node, List<PIP>> byStart = new HashMap<>();
            for (PIP p : n.getPIPs()) byStart.computeIfAbsent(p.getStartNode(), k -> new ArrayList<>()).add(p);
            Set<PIP> reach = new HashSet<>();
            Deque<Node> q = new ArrayDeque<>();
            q.add(src.getConnectedNode());
            Set<Node> seen = new HashSet<>(q);
            while (!q.isEmpty()) {
                List<PIP> out = byStart.get(q.poll());
                if (out == null) continue;
                for (PIP p : out) {
                    reach.add(p);
                    if (seen.add(p.getEndNode())) q.add(p.getEndNode());
                }
            }
            if (reach.size() == n.getPIPs().size()) continue;
            discNets++;
            List<PIP> keepP = new ArrayList<>();
            for (PIP p : n.getPIPs()) {
                if (reach.contains(p)) keepP.add(p);
                else if (rmPips.contains(p)) orphRm++;
                else { orphStatic++; keepP.add(p); }
            }
            n.setPIPs(keepP);
            if (discNets <= 20) System.out.println("RW_DISC " + n.getName());
        }
        System.out.println("RW_STITCH boundary nets now=" + bNow.size() + " disconnected=" + discNets
                + " droppedRmOrphanPips=" + orphRm + " staticOrphanPips=" + orphStatic);
        int upd = DesignTools.updatePinsIsRouted(base);
        t("cleanup");
        List<SitePinInst> unrouted = PartialRouter.getUnroutedPins(base);
        System.out.println("RW_STITCH updatePinsIsRouted=" + upd + " unrouted pins=" + unrouted.size());
        int shown = 0;
        for (SitePinInst p : unrouted) {
            if (shown++ < 60) System.out.println("RW_UNROUTED " + p.getNet().getName() + " " + p);
        }
        stats("stitched", base);
        if (route && !unrouted.isEmpty()) {
            PartialRouter.routeDesignPartialNonTimingDriven(base, unrouted, false);
            t("rwroute partial");
            System.out.println("RW_STITCH after route unrouted=" + PartialRouter.getUnroutedPins(base).size());
        }
        base.writeCheckpoint(a[7]);
        t("write");
    }
}
