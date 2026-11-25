import 'dart:math';

import '../../models/customer.dart';
import '../../models/customer_ledger.dart';
import '../../models/inventory_item.dart';
import '../../models/medicine.dart';
import '../../models/order.dart';
import '../../models/prescription.dart';
import '../../models/purchase_order.dart';
import '../../models/rider.dart';
import '../../models/supplier.dart';
import '../../models/supplier_ledger.dart';
import '../utils/money.dart';

/// Demo seed data (SRS §8.2): realistic **fictional** sample data only —
/// no real client data, no real prices, no real stock.
///
/// Everything is generated deterministically (fixed [Random] seeds) and
/// relative to `DateTime.now()`, so "today" always has sales and the
/// dashboards always show live figures whenever the demo runs, while the
/// figures themselves are stable across runs.
///
/// Coverage: 180 sample medicines (14 core + 166 generated, Day 5),
/// ~30 days of orders across the 2 demo branches (DHA busier than
/// Gulberg — different figures per branch), per-branch inventory with
/// 1–3 batches per medicine and mixed expiry (some near-expiry, a few
/// expired, for the alerts radar), sample customers, suppliers and
/// prescriptions (some pending review).

/// The 14 original sample medicines (fictional catalogue, plausible
/// names/prices). Ids/prices of the three Day 1 medicines are unchanged.
/// Day 5: these stay the catalogue core — [demoMedicines] is the core
/// plus the generated rows below (180 total); seeded orders still pick
/// only from this core, so the 499-order stream is unchanged.
const demoMedicinesCore = <Medicine>[
  Medicine(
    id: 'med-panadol-extra',
    barcode: '8901000000001',
    name: 'Panadol Extra',
    brand: 'GSK',
    categoryId: 'cat-analgesic',
    strength: '500mg',
    packSize: '10 tablets',
    price: 120,
    mrp: 130,
    requiresPrescription: false,
  ),
  Medicine(
    id: 'med-augmentin-625',
    barcode: '8901000000002',
    name: 'Augmentin',
    brand: 'GSK',
    categoryId: 'cat-antibiotic',
    strength: '625mg',
    packSize: '12 tablets',
    price: 1850,
    requiresPrescription: true,
  ),
  Medicine(
    id: 'med-risek-20',
    barcode: '8901000000003',
    name: 'Risek',
    brand: 'Getz Pharma',
    categoryId: 'cat-gastric',
    strength: '20mg',
    packSize: '14 capsules',
    price: 640,
    requiresPrescription: true,
  ),
  Medicine(
    id: 'med-arinac-forte',
    barcode: '8901000000004',
    name: 'Arinac Forte',
    brand: 'Abbott',
    categoryId: 'cat-analgesic',
    strength: '400mg',
    packSize: '10 tablets',
    price: 210,
    requiresPrescription: false,
  ),
  Medicine(
    id: 'med-flagyl-400',
    barcode: '8901000000005',
    name: 'Flagyl',
    brand: 'Sanofi',
    categoryId: 'cat-antibiotic',
    strength: '400mg',
    packSize: '10 tablets',
    price: 180,
    requiresPrescription: true,
  ),
  Medicine(
    id: 'med-brufen-400',
    barcode: '8901000000006',
    name: 'Brufen',
    brand: 'Abbott',
    categoryId: 'cat-analgesic',
    strength: '400mg',
    packSize: '10 tablets',
    price: 150,
    requiresPrescription: false,
  ),
  Medicine(
    id: 'med-concor-5',
    barcode: '8901000000007',
    name: 'Concor',
    brand: 'Merck',
    categoryId: 'cat-cardiac',
    strength: '5mg',
    packSize: '30 tablets',
    price: 980,
    requiresPrescription: true,
  ),
  Medicine(
    id: 'med-glucophage-500',
    barcode: '8901000000008',
    name: 'Glucophage',
    brand: 'Merck',
    categoryId: 'cat-diabetic',
    strength: '500mg',
    packSize: '30 tablets',
    price: 720,
    requiresPrescription: true,
  ),
  Medicine(
    id: 'med-zyrtec-10',
    barcode: '8901000000009',
    name: 'Zyrtec',
    brand: 'UCB',
    categoryId: 'cat-antihistamine',
    strength: '10mg',
    packSize: '10 tablets',
    price: 340,
    requiresPrescription: false,
  ),
  Medicine(
    id: 'med-strepsils',
    barcode: '8901000000010',
    name: 'Strepsils',
    brand: 'Reckitt',
    categoryId: 'cat-throat',
    strength: '—',
    packSize: '24 lozenges',
    price: 260,
    requiresPrescription: false,
  ),
  Medicine(
    id: 'med-ors',
    barcode: '8901000000011',
    name: 'ORS',
    brand: 'Searle',
    categoryId: 'cat-rehydration',
    strength: '—',
    packSize: '10 sachets',
    price: 90,
    requiresPrescription: false,
  ),
  Medicine(
    id: 'med-voltral-50',
    barcode: '8901000000012',
    name: 'Voltral',
    brand: 'Novartis',
    categoryId: 'cat-analgesic',
    strength: '50mg',
    packSize: '20 tablets',
    price: 410,
    requiresPrescription: true,
  ),
  Medicine(
    id: 'med-cac-1000',
    barcode: '8901000000013',
    name: 'Ca-C 1000',
    brand: 'Sandoz',
    categoryId: 'cat-supplement',
    strength: '1000mg',
    packSize: '10 tablets',
    price: 520,
    requiresPrescription: false,
  ),
  Medicine(
    id: 'med-rigix-10',
    barcode: '8901000000014',
    name: 'Rigix',
    brand: 'Tabros',
    categoryId: 'cat-antihistamine',
    strength: '10mg',
    packSize: '10 tablets',
    price: 190,
    requiresPrescription: false,
  ),
];

/// Generated catalogue rows (Day 5): (categoryId, name, brand,
/// requiresPrescription). Strength, pack size, price and barcode are
/// derived deterministically from a fixed [Random] seed in
/// [_generateExtraMedicines], so the catalogue is stable across runs.
/// 166 rows — with the 14 core medicines the catalogue is 180, inside
/// the SRS §8 demo range of ~150–250. All names are fictional sample
/// data (SRS §8.2), in the same plausible style as the core 14.
const _generatedMedicineRows = <(String, String, String, bool)>[
  // Analgesic (14).
  ('cat-analgesic', 'Dolo-650', 'Searle', false),
  ('cat-analgesic', 'Nuberol Forte', 'Abbott', false),
  ('cat-analgesic', 'Febrol', 'Sami', false),
  ('cat-analgesic', 'Relispa', 'Getz Pharma', false),
  ('cat-analgesic', 'Ansaid', 'Pfizer', false),
  ('cat-analgesic', 'Ketorol', 'Sandoz', true),
  ('cat-analgesic', 'Dicloran', 'Novartis', false),
  ('cat-analgesic', 'Mefnac', 'Searle', false),
  ('cat-analgesic', 'Ponstan', 'Pfizer', false),
  ('cat-analgesic', 'Tramal Plus', 'Sandoz', true),
  ('cat-analgesic', 'Doloban', 'Tabros', false),
  ('cat-analgesic', 'Pyregesic', 'CCL', false),
  ('cat-analgesic', 'Dolonex', 'Zafa', false),
  ('cat-analgesic', 'Nims', 'Macter', false),
  // Antibiotic (18).
  ('cat-antibiotic', 'Velosef', 'GSK', true),
  ('cat-antibiotic', 'Ciproxin', 'Bayer', true),
  ('cat-antibiotic', 'Zithromax', 'Pfizer', true),
  ('cat-antibiotic', 'Vibramycin', 'Pfizer', true),
  ('cat-antibiotic', 'Amoxil', 'GSK', true),
  ('cat-antibiotic', 'Keflex', 'Atco', true),
  ('cat-antibiotic', 'Levaquin', 'Sanofi', true),
  ('cat-antibiotic', 'Claforan', 'Sanofi', true),
  ('cat-antibiotic', 'Rocephin', 'Roche', true),
  ('cat-antibiotic', 'Suprax', 'Sanofi', true),
  ('cat-antibiotic', 'Zinnat', 'GSK', true),
  ('cat-antibiotic', 'Erythrocin', 'Abbott', true),
  ('cat-antibiotic', 'Bactrim', 'Roche', true),
  ('cat-antibiotic', 'Ceftum', 'GSK', true),
  ('cat-antibiotic', 'Moxiget', 'Getz Pharma', true),
  ('cat-antibiotic', 'Azee', 'Indus Pharma', true),
  ('cat-antibiotic', 'Azithral', 'Pharmevo', true),
  ('cat-antibiotic', 'Fucidin', 'Sami', true),
  // Gastric (12).
  ('cat-gastric', 'Losec', 'AstraZeneca', true),
  ('cat-gastric', 'Nexium', 'AstraZeneca', true),
  ('cat-gastric', 'Pantop', 'Getz Pharma', true),
  ('cat-gastric', 'Esoz', 'Searle', true),
  ('cat-gastric', 'Ulcenol', 'Abbott', false),
  ('cat-gastric', 'Gaviscon', 'Reckitt', false),
  ('cat-gastric', 'Pevesca', 'Sami', false),
  ('cat-gastric', 'Zantac', 'GSK', false),
  ('cat-gastric', 'Aciloc', 'Tabros', false),
  ('cat-gastric', 'Esomep', 'Pharmevo', true),
  ('cat-gastric', 'Rabium', 'Macter', true),
  ('cat-gastric', 'Gastrol', 'CCL', false),
  // Cardiac (12).
  ('cat-cardiac', 'Norvasc', 'Pfizer', true),
  ('cat-cardiac', 'Tenormin', 'AstraZeneca', true),
  ('cat-cardiac', 'Lopressor', 'Novartis', true),
  ('cat-cardiac', 'Cardilol', 'Sandoz', true),
  ('cat-cardiac', 'Ascard', 'Atco', true),
  ('cat-cardiac', 'Ezicard', 'Getz Pharma', true),
  ('cat-cardiac', 'Amlovas', 'Sami', true),
  ('cat-cardiac', 'Betaloc', 'AstraZeneca', true),
  ('cat-cardiac', 'Carvedil', 'Sandoz', true),
  ('cat-cardiac', 'Isordil', 'Abbott', true),
  ('cat-cardiac', 'Zestril', 'AstraZeneca', true),
  ('cat-cardiac', 'Envas', 'Tabros', true),
  // Diabetic (10).
  ('cat-diabetic', 'Diamicron', 'Sanofi', true),
  ('cat-diabetic', 'Amaryl', 'Sanofi', true),
  ('cat-diabetic', 'Januvia', 'Merck', true),
  ('cat-diabetic', 'Galvus', 'Novartis', true),
  ('cat-diabetic', 'Glyset', 'Bayer', true),
  ('cat-diabetic', 'Daonil', 'Sanofi', true),
  ('cat-diabetic', 'Glibomet', 'Tabros', true),
  ('cat-diabetic', 'Pioglit', 'Getz Pharma', true),
  ('cat-diabetic', 'Sitaglip', 'Pharmevo', true),
  ('cat-diabetic', 'Empaglif', 'Indus Pharma', true),
  // Antihistamine (10).
  ('cat-antihistamine', 'Claritin', 'Bayer', false),
  ('cat-antihistamine', 'Allegra', 'Sanofi', false),
  ('cat-antihistamine', 'Telfast', 'Sanofi', false),
  ('cat-antihistamine', 'Xyzal', 'UCB', false),
  ('cat-antihistamine', 'Piriton', 'GSK', false),
  ('cat-antihistamine', 'Avil', 'Sanofi', false),
  ('cat-antihistamine', 'Cetrin', 'Sami', false),
  ('cat-antihistamine', 'Lorin', 'Tabros', false),
  ('cat-antihistamine', 'Histal', 'CCL', false),
  ('cat-antihistamine', 'Fexet', 'Macter', false),
  // Throat (6).
  ('cat-throat', 'Throcin', 'Sami', false),
  ('cat-throat', 'Tantum', 'Angelini', false),
  ('cat-throat', 'Hexoral', 'Searle', false),
  ('cat-throat', 'Septolete', 'Sandoz', false),
  ('cat-throat', 'Throat-Eze', 'Reckitt', false),
  ('cat-throat', 'Laryn', 'Tabros', false),
  // Rehydration (4).
  ('cat-rehydration', 'Electral', 'Ferozsons', false),
  ('cat-rehydration', 'Rehidrat', 'Sami', false),
  ('cat-rehydration', 'Pedialyte', 'Abbott', false),
  ('cat-rehydration', 'Hydralyte', 'Searle', false),
  // Supplement (12).
  ('cat-supplement', 'Evion', 'Merck', false),
  ('cat-supplement', 'Sangobion', 'Merck', false),
  ('cat-supplement', 'Neurobion', 'Merck', false),
  ('cat-supplement', 'Ca-D3', 'Sandoz', false),
  ('cat-supplement', 'Zincat', 'Sami', false),
  ('cat-supplement', 'Ferros', 'Abbott', false),
  ('cat-supplement', 'Vitabion', 'Pharmevo', false),
  ('cat-supplement', 'Osteocare', 'Sami', false),
  ('cat-supplement', 'Mecobal', 'Tabros', false),
  ('cat-supplement', 'Supradyn', 'Bayer', false),
  ('cat-supplement', 'Nutrifactor', 'Nutrifactor', false),
  ('cat-supplement', 'Caltrate', 'Pfizer', false),
  // Dermatology (12).
  ('cat-dermatology', 'Betnovate', 'GSK', true),
  ('cat-dermatology', 'Dermovate', 'GSK', true),
  ('cat-dermatology', 'Betaderm', 'Sami', false),
  ('cat-dermatology', 'Hydrocort', 'Abbott', false),
  ('cat-dermatology', 'Kenacomb', 'Bristol Myers', false),
  ('cat-dermatology', 'Travocort', 'Bayer', true),
  ('cat-dermatology', 'Neosporin', 'GSK', false),
  ('cat-dermatology', 'Polyfax', 'GSK', false),
  ('cat-dermatology', 'Dermasol', 'Tabros', false),
  ('cat-dermatology', 'Caladryl', 'Sami', false),
  ('cat-dermatology', 'Acnegel', 'Searle', false),
  ('cat-dermatology', 'Retin-A', 'Sami', true),
  // Eye care (8).
  ('cat-eye', 'Tobradex', 'Novartis', true),
  ('cat-eye', 'Vigamox', 'Novartis', true),
  ('cat-eye', 'Systane', 'Novartis', false),
  ('cat-eye', 'Refresh Tears', 'Allergan', false),
  ('cat-eye', 'Optrex', 'Reckitt', false),
  ('cat-eye', 'Visine', 'Sami', false),
  ('cat-eye', 'Ciloxan', 'Novartis', true),
  ('cat-eye', 'Betoptic', 'Novartis', true),
  // Respiratory (12).
  ('cat-respiratory', 'Ventolin', 'GSK', false),
  ('cat-respiratory', 'Seretide', 'GSK', true),
  ('cat-respiratory', 'Symbicort', 'AstraZeneca', true),
  ('cat-respiratory', 'Asthalin', 'Sami', false),
  ('cat-respiratory', 'Pulmicort', 'AstraZeneca', true),
  ('cat-respiratory', 'Singulair', 'Merck', true),
  ('cat-respiratory', 'Montika', 'Getz Pharma', true),
  ('cat-respiratory', 'Bricanyl', 'AstraZeneca', false),
  ('cat-respiratory', 'Foracort', 'Sami', true),
  ('cat-respiratory', 'Aerocort', 'Sami', true),
  ('cat-respiratory', 'Levolin', 'Sami', false),
  ('cat-respiratory', 'Theo-Asthalin', 'Sami', false),
  // Vitamin (10).
  ('cat-vitamin', 'Redoxon', 'Bayer', false),
  ('cat-vitamin', 'Berocca', 'Bayer', false),
  ('cat-vitamin', 'Vit-D3', 'Sami', false),
  ('cat-vitamin', 'B-Complex', 'Tabros', false),
  ('cat-vitamin', 'Folicare', 'Sami', false),
  ('cat-vitamin', 'Iron-F', 'Abbott', false),
  ('cat-vitamin', 'Multi-Vit', 'Pharmevo', false),
  ('cat-vitamin', 'Zincovit', 'Sami', false),
  ('cat-vitamin', 'Cal-D', 'Sandoz', false),
  ('cat-vitamin', 'Omega-3', 'Nutrifactor', false),
  // Antifungal (8).
  ('cat-antifungal', 'Canesten', 'Bayer', false),
  ('cat-antifungal', 'Lamisil', 'Novartis', true),
  ('cat-antifungal', 'Diflucan', 'Pfizer', true),
  ('cat-antifungal', 'Nizoral', 'Sami', false),
  ('cat-antifungal', 'Fungicid', 'Tabros', false),
  ('cat-antifungal', 'Myconaz', 'Sami', false),
  ('cat-antifungal', 'Terbisil', 'Pharmevo', false),
  ('cat-antifungal', 'Clotrim', 'Sami', false),
  // Neurology (10).
  ('cat-neurology', 'Tegretol', 'Novartis', true),
  ('cat-neurology', 'Epival', 'Abbott', true),
  ('cat-neurology', 'Lyrica', 'Pfizer', true),
  ('cat-neurology', 'Gabapin', 'Sami', true),
  ('cat-neurology', 'Neurontin', 'Pfizer', true),
  ('cat-neurology', 'Rivotril', 'Roche', true),
  ('cat-neurology', 'Carbamaz', 'Tabros', true),
  ('cat-neurology', 'Levera', 'Sami', true),
  ('cat-neurology', 'Topamax', 'Sami', true),
  ('cat-neurology', 'Depakine', 'Sanofi', true),
  // Paediatric (8).
  ('cat-paediatric', 'Calpol', 'GSK', false),
  ('cat-paediatric', 'Tempra', 'Sami', false),
  ('cat-paediatric', 'Febrinil', 'Tabros', false),
  ('cat-paediatric', 'Kidz-ORS', 'Searle', false),
  ('cat-paediatric', 'Pediasure', 'Abbott', false),
  ('cat-paediatric', 'Mucolyte Junior', 'Sami', false),
  ('cat-paediatric', 'Zinc Junior', 'Sami', false),
  ('cat-paediatric', 'Vit Junior', 'Pharmevo', false),
];

List<Medicine> _generateExtraMedicines() {
  final random = Random(23);
  const strengths = [
    '250mg',
    '500mg',
    '10mg',
    '20mg',
    '5mg',
    '100mg',
    '40mg',
    '200mg',
    '50mg',
    '30mg',
  ];
  const packs = [
    '10 tablets',
    '20 tablets',
    '30 tablets',
    '14 capsules',
    '100ml syrup',
    '60ml syrup',
    '15g cream',
    '10ml drops',
  ];
  final medicines = <Medicine>[];
  for (var i = 0; i < _generatedMedicineRows.length; i++) {
    final (categoryId, name, brand, requiresPrescription) =
        _generatedMedicineRows[i];
    // Whole-rupee price, rounded to the nearest Rs 5.
    final price = ((60 + random.nextInt(2400)) / 5).round() * 5;
    medicines.add(
      Medicine(
        id: 'med-gen-${(i + 1).toString().padLeft(3, '0')}',
        barcode: '890${2000000000 + i}',
        name: name,
        brand: brand,
        categoryId: categoryId,
        strength: strengths[random.nextInt(strengths.length)],
        packSize: packs[random.nextInt(packs.length)],
        price: price.toDouble(),
        mrp: random.nextBool()
            ? (price * 1.1).roundToDouble()
            : null,
        requiresPrescription: requiresPrescription,
      ),
    );
  }
  return medicines;
}

/// The full demo catalogue: the 14 core medicines plus the 166
/// generated rows — 180 medicines, inside the SRS §8 range of ~150–250.
final List<Medicine> demoMedicines = [
  ...demoMedicinesCore,
  ..._generateExtraMedicines(),
];

/// Sample customers (fictional names/phones, Lahore addresses).
///
/// A few customers carry a khata credit limit (int paisa) — see
/// [generateDemoLedgerEntries] for their opening ledger. `0` means no
/// limit is set.
const demoCustomers = <Customer>[
  Customer(
    id: 'cust-1',
    name: 'Ahmed Raza',
    phone: '0300-1112233',
    creditLimitMinor: 2000000, // Rs 20,000.00
    addresses: [
      CustomerAddress(
        label: 'Home',
        address: 'House 12, Street 4, DHA Phase 2',
        city: 'Lahore',
        isDefault: true,
      ),
    ],
  ),
  Customer(
    id: 'cust-2',
    name: 'Fatima Khan',
    phone: '0300-4445566',
    creditLimitMinor: 1000000, // Rs 10,000.00
    addresses: [
      CustomerAddress(
        label: 'Home',
        address: 'Flat 5, Askari 11',
        city: 'Lahore',
        isDefault: true,
      ),
    ],
  ),
  Customer(
    id: 'cust-3',
    name: 'Bilal Hussain',
    phone: '0321-7788990',
    creditLimitMinor: 1500000, // Rs 15,000.00
    addresses: [
      CustomerAddress(
        label: 'Home',
        address: 'House 8, Gulberg III',
        city: 'Lahore',
        isDefault: true,
      ),
    ],
  ),
  Customer(
    id: 'cust-4',
    name: 'Ayesha Siddiqui',
    phone: '0333-2233445',
    creditLimitMinor: 2000000, // Rs 20,000.00
    addresses: [
      CustomerAddress(
        label: 'Home',
        address: 'House 21, Model Town',
        city: 'Lahore',
        isDefault: true,
      ),
    ],
  ),
  Customer(
    id: 'cust-5',
    name: 'Usman Ghani',
    phone: '0301-6677889',
    addresses: [
      CustomerAddress(
        label: 'Office',
        address: 'Office 3, Main Boulevard, Gulberg',
        city: 'Lahore',
        isDefault: true,
      ),
    ],
  ),
  Customer(
    id: 'cust-6',
    name: 'Zainab Tariq',
    phone: '0345-9900112',
    addresses: [
      CustomerAddress(
        label: 'Home',
        address: 'House 45, DHA Phase 5',
        city: 'Lahore',
        isDefault: true,
      ),
    ],
  ),
  Customer(
    id: 'cust-7',
    name: 'Hassan Ali',
    phone: '0302-3344556',
    addresses: [
      CustomerAddress(
        label: 'Home',
        address: 'House 9, Johar Town',
        city: 'Lahore',
        isDefault: true,
      ),
    ],
  ),
  Customer(
    id: 'cust-8',
    name: 'Maryam Aslam',
    phone: '0312-5566778',
    addresses: [
      CustomerAddress(
        label: 'Home',
        address: 'House 17, Faisal Town',
        city: 'Lahore',
        isDefault: true,
      ),
    ],
  ),
];

/// Opening khata (credit ledger) entries for the seeded customers
/// (Day 6, SRS FR-POS-09). Deterministic, relative to `now`.
///
/// Outstanding balances after seeding:
/// - Ahmed Raza (cust-1): Rs 5,500.00 (credit 8,500 − payment 3,000).
/// - Fatima Khan (cust-2): Rs 2,500.00.
/// - Bilal Hussain (cust-3): Rs 12,000.00.
/// - Ayesha Siddiqui (cust-4): Rs 12,000.00 (15,000 − 5,000 + 2,000).
/// - Usman Ghani (cust-5): Rs 0.00 (paid in full).
/// - Zainab Tariq, Hassan Ali, Maryam Aslam: no khata history.
List<LedgerEntry> generateDemoLedgerEntries({DateTime? now}) {
  final reference = now ?? DateTime.now();
  final today = DateTime(reference.year, reference.month, reference.day);
  DateTime daysAgo(int days, [int hour = 11]) =>
      today.subtract(Duration(days: days)).add(Duration(hours: hour));
  return [
    LedgerEntry(
      id: 'led-1',
      customerId: 'cust-1',
      kind: LedgerEntryKind.credit,
      amountMinor: 850000, // Rs 8,500.00
      reason: 'Udhaar — regular monthly medicines',
      balanceAfterMinor: 850000,
      createdAt: daysAgo(12),
    ),
    LedgerEntry(
      id: 'led-2',
      customerId: 'cust-1',
      kind: LedgerEntryKind.payment,
      amountMinor: -300000, // Rs 3,000.00
      reason: 'Payment received — cash',
      balanceAfterMinor: 550000,
      createdAt: daysAgo(5),
    ),
    LedgerEntry(
      id: 'led-3',
      customerId: 'cust-2',
      kind: LedgerEntryKind.credit,
      amountMinor: 250000, // Rs 2,500.00
      reason: 'Udhaar — BP medicines',
      balanceAfterMinor: 250000,
      createdAt: daysAgo(8),
    ),
    LedgerEntry(
      id: 'led-4',
      customerId: 'cust-3',
      kind: LedgerEntryKind.credit,
      amountMinor: 1200000, // Rs 12,000.00
      reason: 'Udhaar — family medicines',
      balanceAfterMinor: 1200000,
      createdAt: daysAgo(3),
    ),
    LedgerEntry(
      id: 'led-5',
      customerId: 'cust-4',
      kind: LedgerEntryKind.credit,
      amountMinor: 1500000, // Rs 15,000.00
      reason: 'Udhaar — diabetes medicines',
      balanceAfterMinor: 1500000,
      createdAt: daysAgo(20),
    ),
    LedgerEntry(
      id: 'led-6',
      customerId: 'cust-4',
      kind: LedgerEntryKind.payment,
      amountMinor: -500000, // Rs 5,000.00
      reason: 'Payment received — cash',
      balanceAfterMinor: 1000000,
      createdAt: daysAgo(18),
    ),
    LedgerEntry(
      id: 'led-7',
      customerId: 'cust-4',
      kind: LedgerEntryKind.credit,
      amountMinor: 200000, // Rs 2,000.00
      reason: 'Udhaar — top-up medicines',
      balanceAfterMinor: 1200000,
      createdAt: daysAgo(2),
    ),
    LedgerEntry(
      id: 'led-8',
      customerId: 'cust-5',
      kind: LedgerEntryKind.credit,
      amountMinor: 400000, // Rs 4,000.00
      reason: 'Udhaar — office first-aid stock',
      balanceAfterMinor: 400000,
      createdAt: daysAgo(15),
    ),
    LedgerEntry(
      id: 'led-9',
      customerId: 'cust-5',
      kind: LedgerEntryKind.payment,
      amountMinor: -400000, // Rs 4,000.00
      reason: 'Payment received — paid in full',
      balanceAfterMinor: 0,
      createdAt: daysAgo(10),
    ),
  ];
}

/// Sample suppliers (fictional distributors).
///
/// Day 7: there is NO stored balance on a supplier — the payable is
/// always computed from the ledger (see
/// [generateDemoSupplierLedgerEntries]). The opening balances below
/// live as ledger entries: Sami Rs 125,000.00, MedServe Rs 48,250.00,
/// CareLine Rs 21,000.00, Hassan Pharma Traders settled (Rs 0.00).
const demoSuppliers = <Supplier>[
  Supplier(
    id: 'sup-sami',
    name: 'Sami Pharmaceuticals',
    contactPerson: 'Sami Ullah',
    phone: '0300-7778899',
    email: 'orders@sami-demo.pk',
    address: 'Plot 12, Industrial Area, Lahore',
    taxNumber: 'NTN-DEMO-1001',
    paymentTerms: 'Net 30 days',
  ),
  Supplier(
    id: 'sup-medserve',
    name: 'MedServe Distributors',
    contactPerson: 'Nadia Iqbal',
    phone: '0321-1122334',
    email: 'sales@medserve-demo.pk',
    address: 'Main Boulevard, Gulberg III, Lahore',
    taxNumber: 'NTN-DEMO-1002',
    paymentTerms: 'Net 15 days',
  ),
  Supplier(
    id: 'sup-hassan-traders',
    name: 'Hassan Pharma Traders',
    contactPerson: 'Hassan Javed',
    phone: '0333-4455667',
    address: 'Akbar Mandi, Lahore',
    paymentTerms: 'Cash on delivery',
  ),
  Supplier(
    id: 'sup-careline',
    name: 'CareLine Supplies',
    contactPerson: 'Omar Farooq',
    phone: '0301-9988776',
    email: 'info@careline-demo.pk',
    address: 'DHA Phase 2, Lahore',
    taxNumber: 'NTN-DEMO-1004',
    paymentTerms: 'Net 30 days',
  ),
];

/// Opening supplier payables (Day 7, SRS FR-PUR-04). Deterministic,
/// relative to `now`. Each entry is an opening purchase balance; the
/// computed outstanding per supplier is:
///
/// - Sami Pharmaceuticals (sup-sami): Rs 125,000.00.
/// - MedServe Distributors (sup-medserve): Rs 48,250.00
///   (Rs 60,000.00 purchase − Rs 11,750.00 payment).
/// - Hassan Pharma Traders: no history (Rs 0.00).
/// - CareLine Supplies (sup-careline): Rs 21,000.00.
List<SupplierLedgerEntry> generateDemoSupplierLedgerEntries({
  DateTime? now,
}) {
  final reference = now ?? DateTime.now();
  final today = DateTime(reference.year, reference.month, reference.day);
  DateTime daysAgo(int days, [int hour = 10]) =>
      today.subtract(Duration(days: days)).add(Duration(hours: hour));
  return [
    SupplierLedgerEntry(
      id: 'sled-1',
      supplierId: 'sup-sami',
      kind: SupplierLedgerEntryKind.purchase,
      amountMinor: 12500000, // Rs 125,000.00
      reason: 'Opening balance — purchases before demo period',
      balanceAfterMinor: 12500000,
      createdAt: daysAgo(28),
    ),
    SupplierLedgerEntry(
      id: 'sled-2',
      supplierId: 'sup-medserve',
      kind: SupplierLedgerEntryKind.purchase,
      amountMinor: 6000000, // Rs 60,000.00
      reason: 'Opening balance — purchases before demo period',
      balanceAfterMinor: 6000000,
      createdAt: daysAgo(25),
    ),
    SupplierLedgerEntry(
      id: 'sled-3',
      supplierId: 'sup-medserve',
      kind: SupplierLedgerEntryKind.payment,
      amountMinor: -1175000, // Rs 11,750.00
      reason: 'Payment made — bank transfer',
      balanceAfterMinor: 4825000,
      createdAt: daysAgo(20),
    ),
    SupplierLedgerEntry(
      id: 'sled-4',
      supplierId: 'sup-careline',
      kind: SupplierLedgerEntryKind.purchase,
      amountMinor: 2100000, // Rs 21,000.00
      reason: 'Opening balance — purchases before demo period',
      balanceAfterMinor: 2100000,
      createdAt: daysAgo(15),
    ),
  ];
}

/// Seed purchase orders (Day 7, SRS FR-PUR-01/02): a live mix across
/// both branches — two drafts, one approved, one partially received,
/// one received, one cancelled — so every PO status is visible in the
/// demo. These POs predate the ledger seed (their value is NOT in the
/// opening balances above); only POs received during the session add
/// ledger entries, through the receiving flow.
List<PurchaseOrder> generateDemoPurchaseOrders({DateTime? now}) {
  final reference = now ?? DateTime.now();
  final today = DateTime(reference.year, reference.month, reference.day);
  DateTime daysAgo(int days, [int hour = 10]) =>
      today.subtract(Duration(days: days)).add(Duration(hours: hour));
  return [
    PurchaseOrder(
      id: 'po-dha-1001',
      poNumber: 'PO-DHA-1001',
      supplierId: 'sup-sami',
      branchId: 'branch-dha-main',
      status: PurchaseOrderStatus.approved,
      items: const [
        PurchaseOrderItem(
          medicineId: 'med-augmentin-625',
          medicineName: 'Augmentin',
          quantityOrdered: 100,
          unitCostMinor: 150000, // Rs 1,500.00
        ),
        PurchaseOrderItem(
          medicineId: 'med-panadol-extra',
          medicineName: 'Panadol Extra',
          quantityOrdered: 200,
          unitCostMinor: 10000, // Rs 100.00
        ),
      ],
      approvedBy: 'Bilal Ahmed',
      notes: 'Monthly antibiotic restock.',
      createdAt: daysAgo(2),
      updatedAt: daysAgo(1),
    ),
    PurchaseOrder(
      id: 'po-dha-1002',
      poNumber: 'PO-DHA-1002',
      supplierId: 'sup-medserve',
      branchId: 'branch-dha-main',
      status: PurchaseOrderStatus.draft,
      items: const [
        PurchaseOrderItem(
          medicineId: 'med-risek-20',
          medicineName: 'Risek',
          quantityOrdered: 50,
          unitCostMinor: 55000, // Rs 550.00
        ),
      ],
      notes: 'Awaiting manager approval.',
      createdAt: daysAgo(1),
      updatedAt: daysAgo(1),
    ),
    PurchaseOrder(
      id: 'po-dha-1003',
      poNumber: 'PO-DHA-1003',
      supplierId: 'sup-careline',
      branchId: 'branch-dha-main',
      status: PurchaseOrderStatus.received,
      items: const [
        PurchaseOrderItem(
          medicineId: 'med-flagyl-400',
          medicineName: 'Flagyl',
          quantityOrdered: 100,
          quantityReceived: 100,
          unitCostMinor: 15000, // Rs 150.00
        ),
      ],
      approvedBy: 'Bilal Ahmed',
      notes: 'Received in full yesterday.',
      createdAt: daysAgo(4),
      updatedAt: daysAgo(1),
    ),
    PurchaseOrder(
      id: 'po-glb-1004',
      poNumber: 'PO-GLB-1004',
      supplierId: 'sup-sami',
      branchId: 'branch-demo-gulberg',
      status: PurchaseOrderStatus.partiallyReceived,
      items: const [
        PurchaseOrderItem(
          medicineId: 'med-concor-5',
          medicineName: 'Concor',
          quantityOrdered: 60,
          quantityReceived: 30,
          unitCostMinor: 85000, // Rs 850.00
        ),
      ],
      approvedBy: 'Bilal Ahmed',
      notes: 'Half the shipment arrived; remainder expected this week.',
      createdAt: daysAgo(3),
      updatedAt: daysAgo(1),
    ),
    PurchaseOrder(
      id: 'po-glb-1005',
      poNumber: 'PO-GLB-1005',
      supplierId: 'sup-hassan-traders',
      branchId: 'branch-demo-gulberg',
      status: PurchaseOrderStatus.draft,
      items: const [
        PurchaseOrderItem(
          medicineId: 'med-zyrtec-10',
          medicineName: 'Zyrtec',
          quantityOrdered: 80,
          unitCostMinor: 30000, // Rs 300.00
        ),
      ],
      notes: 'Draft for the Gulberg allergy season.',
      createdAt: daysAgo(0),
      updatedAt: daysAgo(0),
    ),
    PurchaseOrder(
      id: 'po-dha-1006',
      poNumber: 'PO-DHA-1006',
      supplierId: 'sup-medserve',
      branchId: 'branch-dha-main',
      status: PurchaseOrderStatus.cancelled,
      items: const [
        PurchaseOrderItem(
          medicineId: 'med-brufen-400',
          medicineName: 'Brufen',
          quantityOrdered: 50,
          unitCostMinor: 12000, // Rs 120.00
        ),
      ],
      notes: 'Cancelled — duplicate of PO-DHA-1001.',
      createdAt: daysAgo(6),
      updatedAt: daysAgo(5),
    ),
  ];
}

/// Sample delivery riders (fictional). Two per demo branch area; all
/// active. Orders created by the Day 4 flow assign one of these when
/// the fulfilment is delivery.
const demoRiders = <Rider>[
  Rider(
    id: 'rider-1',
    name: 'Bilal Ahmed',
    phone: '0300-1010101',
    vehicle: 'Honda CD 70 — LEA-1234',
  ),
  Rider(
    id: 'rider-2',
    name: 'Usman Khalid',
    phone: '0300-2020202',
    vehicle: 'Suzuki GD 110 — LEA-5678',
  ),
  Rider(
    id: 'rider-3',
    name: 'Ahmed Nawaz',
    phone: '0300-3030303',
    vehicle: 'Honda CD 70 — LEA-9012',
  ),
  Rider(
    id: 'rider-4',
    name: 'Zahid Hussain',
    phone: '0300-4040404',
    vehicle: 'United 70 — LEA-3456',
    active: false,
  ),
];

/// Branch ids used by the seed data (must match `demoBranches`).
const demoSeedBranchIds = ['branch-dha-main', 'branch-demo-gulberg'];

/// Generates ~30 days of orders ending today, for both demo branches.
///
/// DHA is the busier branch (8–13 orders/day) and Gulberg quieter
/// (4–7 orders/day), so the two branches show different figures.
/// Deterministic: the same seed always produces the same orders.
List<Order> generateDemoOrders({DateTime? now}) {
  final reference = now ?? DateTime.now();
  final today = DateTime(reference.year, reference.month, reference.day);
  final random = Random(42);
  final orders = <Order>[];
  var sequence = 1000;

  for (final branchId in demoSeedBranchIds) {
    final branchCode = branchId == 'branch-dha-main' ? 'dha' : 'glb';
    final isDha = branchId == 'branch-dha-main';
    for (var daysAgo = 29; daysAgo >= 0; daysAgo--) {
      final day = today.subtract(Duration(days: daysAgo));
      final orderCount = isDha
          ? 8 + random.nextInt(6)
          : 4 + random.nextInt(4);
      for (var i = 0; i < orderCount; i++) {
        sequence++;
        final itemCount = 1 + random.nextInt(3);
        final picked = <Medicine>{};
        while (picked.length < itemCount) {
          // Orders pick only from the 14 core medicines (Day 5): the
          // generated catalogue rows never enter seeded orders, so the
          // 499-order stream — and every Day 4 test on it — is
          // unchanged by the catalogue expansion.
          picked.add(
            demoMedicinesCore[random.nextInt(demoMedicinesCore.length)],
          );
        }
        final items = picked
            .map(
              (medicine) => OrderItem(
                medicineId: medicine.id,
                medicineName: medicine.name,
                quantity: 1 + random.nextInt(3),
                unitPrice: medicine.price,
              ),
            )
            .toList();
        final total = items.fold<double>(
          0,
          (sum, item) => sum + item.lineTotal,
        );
        final customer =
            demoCustomers[random.nextInt(demoCustomers.length)];
        final createdAt = DateTime(
          day.year,
          day.month,
          day.day,
          9 + random.nextInt(12),
          random.nextInt(60),
        );
        final status = daysAgo == 0 && i < 2
            // Guarantee a live queue every day: the first two orders
            // of each branch today are always New, so the "New"
            // filter is never empty in the demo.
            ? OrderStatus.newOrder
            : _statusFor(random, daysAgo);
        // Source / fulfilment mix: most orders come by phone and are
        // delivered; walk-ins are always pickup. Seeded orders carry
        // no discount, so totalAmount still equals the sum of lines.
        final sourceRoll = random.nextInt(100);
        final source = sourceRoll < 55
            ? OrderSource.phone
            : sourceRoll < 80
            ? OrderSource.whatsapp
            : OrderSource.walkIn;
        final fulfillment = source == OrderSource.walkIn
            ? FulfillmentType.pickup
            : (random.nextInt(100) < 85
                  ? FulfillmentType.delivery
                  : FulfillmentType.pickup);
        // Orders already out for delivery (or delivered) had a rider.
        final riderId =
            status == OrderStatus.outForDelivery ||
                status == OrderStatus.delivered
            ? demoRiders[random.nextInt(3)].id
            : null;
        // Day 7: today's first order of each branch carries a pending
        // prescription (`rx-dha-1` / `rx-glb-11`, forced pending in
        // generateDemoPrescriptions), so the dispatch guard is live
        // in the demo — approving that prescription unblocks the order.
        // (Prescription ids run 1–10 for DHA, 11–20 for Gulberg.)
        final prescriptionId = daysAgo == 0 && i == 0
            ? (isDha ? 'rx-dha-1' : 'rx-glb-11')
            : null;
        orders.add(
          Order(
            id: 'ord-$branchCode-$sequence',
            customerId: customer.id,
            branchId: branchId,
            riderId: riderId,
            items: items,
            deliveryAddress: fulfillment == FulfillmentType.pickup
                ? 'Pickup from branch'
                : customer.addresses.first.address,
            status: status,
            source: source,
            fulfillment: fulfillment,
            totalAmount: total,
            prescriptionId: prescriptionId,
            createdAt: createdAt,
          ),
        );
      }
    }
  }
  return orders;
}

OrderStatus _statusFor(Random random, int daysAgo) {
  final roll = random.nextInt(100);
  if (daysAgo == 0) {
    // Today: a live mix across the queue.
    if (roll < 25) return OrderStatus.placed;
    if (roll < 40) return OrderStatus.confirmed;
    if (roll < 60) return OrderStatus.preparing;
    if (roll < 75) return OrderStatus.outForDelivery;
    if (roll < 95) return OrderStatus.delivered;
    return OrderStatus.cancelled;
  }
  // Past days: mostly delivered, a few cancelled.
  if (roll < 90) return OrderStatus.delivered;
  return OrderStatus.cancelled;
}

/// Generates per-branch inventory: 1–3 batch rows per medicine per
/// branch (Day 5 — one [InventoryItem] is one batch), with mixed expiry
/// — most batches far out, ~25% near-expiry (10–29 days), some within
/// days, a few already expired — and ~20% of rows at/below the
/// low-stock threshold, so the alerts radar is live. Each batch carries
/// a manufacture date (12–36 months before its expiry) and a cost price
/// of roughly 70–90% of the sale price.
List<InventoryItem> generateDemoInventory({DateTime? now}) {
  final reference = now ?? DateTime.now();
  final today = DateTime(reference.year, reference.month, reference.day);
  final random = Random(7);
  final items = <InventoryItem>[];
  var sequence = 0;

  for (final branchId in demoSeedBranchIds) {
    final branchCode = branchId == 'branch-dha-main' ? 'DHA' : 'GLB';
    for (var index = 0; index < demoMedicines.length; index++) {
      final medicine = demoMedicines[index];
      final batchCount = 1 + random.nextInt(3);
      for (var batchIndex = 0; batchIndex < batchCount; batchIndex++) {
        sequence++;
        final roll = random.nextInt(100);
        final int expiryDays;
        if (roll < 55) {
          expiryDays = 90 + random.nextInt(450);
        } else if (roll < 80) {
          expiryDays = 10 + random.nextInt(20); // near-expiry
        } else if (roll < 92) {
          expiryDays = 1 + random.nextInt(9); // expiring within days
        } else {
          expiryDays = -random.nextInt(10); // already expired
        }
        final quantity = random.nextInt(100) < 20
            ? random.nextInt(9) // low stock: 0–8
            : 15 + random.nextInt(110);
        final expiryDate = today.add(Duration(days: expiryDays));
        final shelfMonths = 12 + random.nextInt(25);
        items.add(
          InventoryItem(
            id: 'inv-$branchCode-$sequence',
            medicineId: medicine.id,
            branchId: branchId,
            quantity: quantity,
            lowStockThreshold: 10,
            batchNo:
                '$branchCode-${index + 1}-${batchIndex + 1}-${100 + random.nextInt(900)}',
            expiryDate: expiryDate,
            mfgDate: expiryDate.subtract(
              Duration(days: shelfMonths * 30),
            ),
            costMinor: rupeesToMinorUnits(
              medicine.price * (0.7 + random.nextDouble() * 0.2),
            ),
          ),
        );
      }
    }
  }
  return items;
}

/// Generates sample prescriptions per branch: a live mix of pending,
/// approved and rejected reviews from the last few days.
///
/// Day 7: `imageUrl` is a **bundled sample asset** (never a network
/// URL and never a real patient photo): the two sample images under
/// `assets/images/prescriptions/` are clearly marked SAMPLE. On Spark
/// there is no Cloud Storage, so prescription photos stay on-device in
/// production (see D2) — the demo carries no real images.
///
/// The first prescription of each branch (`rx-dha-1`, `rx-glb-11`)
/// is always pending and is linked to today's first order of that
/// branch, so the dispatch guard is demonstrable end to end.
List<Prescription> generateDemoPrescriptions({DateTime? now}) {
  final reference = now ?? DateTime.now();
  final today = DateTime(reference.year, reference.month, reference.day);
  final random = Random(11);
  final prescriptions = <Prescription>[];
  const statuses = [
    PrescriptionStatus.pending,
    PrescriptionStatus.pending,
    PrescriptionStatus.approved,
    PrescriptionStatus.approved,
    PrescriptionStatus.approved,
    PrescriptionStatus.rejected,
    PrescriptionStatus.needsClearerPhoto,
  ];
  var sequence = 0;

  for (final branchId in demoSeedBranchIds) {
    final branchCode = branchId == 'branch-dha-main' ? 'dha' : 'glb';
    for (var i = 0; i < 10; i++) {
      sequence++;
      final customer =
          demoCustomers[random.nextInt(demoCustomers.length)];
      prescriptions.add(
        Prescription(
          id: 'rx-$branchCode-$sequence',
          customerId: customer.id,
          imageUrl:
              'assets/images/prescriptions/sample-prescription-${sequence % 2 + 1}.png',
          status: i == 0
              ? PrescriptionStatus.pending
              : statuses[random.nextInt(statuses.length)],
          medicinesText: i % 2 == 0
              ? 'Augmentin 625mg — 1 tablet twice daily (5 days); Panadol Extra 500mg — as needed'
              : 'Concor 5mg — 1 tablet daily; Glucophage 500mg — 1 tablet twice daily',
          createdAt: today.subtract(
            Duration(
              days: random.nextInt(5),
              hours: random.nextInt(10),
            ),
          ),
        ),
      );
    }
  }
  return prescriptions;
}
